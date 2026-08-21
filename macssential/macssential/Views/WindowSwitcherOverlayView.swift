import AppKit
import SwiftUI

/// Selection state shared between the overlay panel and its SwiftUI content.
///
/// Exists so that cycling (which can fire many times per second while Tab
/// repeats) and thumbnails arriving one by one mutate observable state instead of
/// rebuilding the panel and its hosting view on every update.
@Observable
@MainActor
final class WindowSwitcherOverlayModel {
    var windows: [SwitcherWindow] = []
    var selectedIndex = 0
    /// Captured window snapshots keyed by `SwitcherWindow.id`. Absent entries render
    /// the app-icon fallback, which is the permanent state when Screen Recording is
    /// not granted. Cleared on every open so a tile never shows a stale snapshot.
    var thumbnails: [String: NSImage] = [:]
}

/// Container view that owns ALL mouse handling for the overlay.
///
/// Why AppKit rather than SwiftUI `.onHover` / `.onTapGesture`: the overlay lives in
/// a `.nonactivatingPanel` that is never key and belongs to an app that is usually
/// not active. SwiftUI's hover tracking is installed for the active application, so
/// it is not dependable here, whereas an `NSTrackingArea` with `.activeAlways`
/// delivers `mouseMoved` regardless of key or active state — exactly the guarantee
/// this overlay needs.
///
/// `hitTest` deliberately swallows everything: the hosted SwiftUI view is purely
/// presentational, so routing every event through the pure
/// `WindowSwitcherEngine.tileIndex` hit-test keeps one unambiguous, unit-tested
/// source of truth for which tile the pointer is over.
@MainActor
final class SwitcherGridTrackingView: NSView {

    var onHoverIndex: ((Int) -> Void)?
    var onActivateIndex: ((Int) -> Void)?
    /// Drives the grid shape used for hit-testing. Set on every open.
    var windowCount = 0

    /// Top-left origin, matching the coordinate space `tileIndex` documents, so the
    /// AppKit→grid conversion is a plain `convert(_:from:)` with no manual y flip.
    override var isFlipped: Bool { true }

    /// The panel never becomes key, so without this the first click would be
    /// swallowed as a window-activation click instead of selecting a tile.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        return bounds.contains(local) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        // .inVisibleRect keeps the area sized to the view across the resize that
        // every open performs; .activeAlways is what makes this work in a panel
        // belonging to an inactive app.
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    private func tileIndex(for event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        return WindowSwitcherEngine.tileIndex(
            at: point,
            gridOrigin: WindowSwitcherOverlayView.gridOrigin,
            tileSize: WindowSwitcherOverlayView.tileSize,
            spacing: WindowSwitcherOverlayView.spacing,
            layout: WindowSwitcherEngine.gridLayout(
                count: windowCount, maxColumns: WindowSwitcherOverlayView.maxColumns),
            count: windowCount
        )
    }

    override func mouseMoved(with event: NSEvent) {
        guard let index = tileIndex(for: event) else { return }
        onHoverIndex?(index)
    }

    /// Consumed without acting: AppKit only delivers `mouseUp` to the view that
    /// received the matching `mouseDown`, and committing on release (not press)
    /// matches how the keyboard path commits on Cmd release.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard let index = tileIndex(for: event) else { return }
        onActivateIndex?(index)
    }
}

/// Owns the borderless panel that renders the switcher.
@MainActor
final class WindowSwitcherOverlayController {

    private let model = WindowSwitcherOverlayModel()
    private var panel: NSPanel?
    private var trackingView: SwitcherGridTrackingView?

    /// Pointer moved onto a tile. Wired by the module to move the shared selection.
    var onHoverIndex: ((Int) -> Void)?
    /// Tile clicked. Wired by the module to commit through the normal raise path.
    var onActivateIndex: ((Int) -> Void)?

    /// Opens (or re-opens) the overlay with a fresh window list.
    func show(windows: [SwitcherWindow], selectedIndex: Int) {
        model.windows = windows
        model.selectedIndex = selectedIndex
        // A snapshot is only valid for the session it was taken in.
        model.thumbnails = [:]

        let panel = ensurePanel()
        let size = WindowSwitcherOverlayView.contentSize(windowCount: windows.count)

        // Both the container and the hosting view are rebuilt on every open rather
        // than reused: a retained NSHostingView can keep rendering against the state
        // it first evaluated (same stale-content failure fixed in quick-260625-mxd
        // for the menu panel).
        let container = SwitcherGridTrackingView()
        container.frame = NSRect(origin: .zero, size: size)
        container.windowCount = windows.count
        container.onHoverIndex = { [weak self] index in self?.onHoverIndex?(index) }
        container.onActivateIndex = { [weak self] index in self?.onActivateIndex?(index) }

        let hosting = NSHostingView(rootView: WindowSwitcherOverlayView(model: model))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        container.addSubview(hosting)

        trackingView = container
        panel.contentView = container
        panel.setContentSize(size)
        panel.setFrameOrigin(originCenteringSize(size))
        // orderFrontRegardless, not makeKeyAndOrderFront: the overlay must appear
        // without macssential becoming active.
        panel.orderFrontRegardless()
    }

    /// Moves the highlight without touching the panel or its hosting view.
    func updateSelection(windows: [SwitcherWindow], selectedIndex: Int) {
        model.windows = windows
        model.selectedIndex = selectedIndex
    }

    /// Fills in one tile as its snapshot arrives. Tiles appear immediately with app
    /// icons and upgrade progressively, so a slow capture never delays the overlay.
    func setThumbnail(_ image: NSImage, for id: String) {
        model.thumbnails[id] = image
    }

    func dismiss() {
        panel?.orderOut(nil)
        model.thumbnails = [:]
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let created = NSPanel(
            contentRect: NSRect(origin: .zero,
                                size: WindowSwitcherOverlayView.contentSize(windowCount: 0)),
            // .nonactivatingPanel is essential: a panel that takes key focus would
            // pull activation away from the app the user is holding Cmd inside,
            // and the modifier state driving the session would be lost. Accepting
            // mouse events (below) does not change that — a non-activating panel
            // can be clicked without its app becoming active.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        created.isFloatingPanel = true
        // Above normal windows and full-screen apps, matching where a system
        // switcher would draw.
        created.level = .popUpMenu
        created.hidesOnDeactivate = false
        created.isOpaque = false
        created.backgroundColor = .clear
        created.hasShadow = true
        // Mouse selection needs both: events must reach the panel at all, and
        // mouseMoved must be generated while the pointer travels across tiles.
        created.ignoresMouseEvents = false
        created.acceptsMouseMovedEvents = true
        created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel = created
        return created
    }

    /// Centers on the screen holding the pointer — the display the user is
    /// working on — falling back to the main screen, then clamps so a wide
    /// multi-row grid stays fully on screen.
    private func originCenteringSize(_ size: NSSize) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return .zero }

        // max(..., min) guards the case where the grid is wider or taller than the
        // screen: clamping then pins the top-left corner rather than inverting.
        let x = min(max(visible.midX - size.width / 2, visible.minX),
                    max(visible.maxX - size.width, visible.minX))
        let y = min(max(visible.midY - size.height / 2, visible.minY),
                    max(visible.maxY - size.height, visible.minY))
        return NSPoint(x: x, y: y)
    }
}

/// Grid of window tiles: snapshot (or a large app icon), app-icon badge, title.
///
/// Every dimension here is also consumed by `SwitcherGridTrackingView` through
/// `contentSize`/`gridOrigin`, so the AppKit hit-test geometry and the SwiftUI
/// layout are derived from one set of constants and cannot drift apart.
struct WindowSwitcherOverlayView: View {

    static let tileSize = CGSize(width: 160, height: 116)
    static let spacing: CGFloat = 12
    static let maxColumns = 5
    static let outerPadding: CGFloat = 16

    /// Top-left corner of tile 0, in the tracking view's flipped coordinate space.
    static var gridOrigin: CGPoint { CGPoint(x: outerPadding, y: outerPadding) }

    /// Inner tile geometry: thumbnail area, caption strip, and the 4pt inset
    /// between them and the tile edge. 4 + 88 + 4 + 16 + 4 == 116.
    private static let tileInset: CGFloat = 4
    private static let thumbWidth = tileSize.width - tileInset * 2
    private static let thumbHeight: CGFloat = 88
    private static let captionHeight: CGFloat = 16

    private static let emptySize = CGSize(width: 260, height: 72)

    let model: WindowSwitcherOverlayModel

    /// Exact panel size for a window count — computed rather than measured via
    /// `fittingSize` so the panel frame, the grid layout and the hit-test all agree
    /// to the point.
    static func contentSize(windowCount: Int) -> CGSize {
        let layout = WindowSwitcherEngine.gridLayout(count: windowCount, maxColumns: maxColumns)
        guard layout.columns > 0, layout.rows > 0 else { return emptySize }
        return CGSize(
            width: CGFloat(layout.columns) * tileSize.width
                 + CGFloat(layout.columns - 1) * spacing
                 + outerPadding * 2,
            height: CGFloat(layout.rows) * tileSize.height
                  + CGFloat(layout.rows - 1) * spacing
                  + outerPadding * 2
        )
    }

    var body: some View {
        let layout = WindowSwitcherEngine.gridLayout(
            count: model.windows.count, maxColumns: Self.maxColumns)
        let size = Self.contentSize(windowCount: model.windows.count)

        return Group {
            if layout.columns == 0 {
                Text(String(localized: "module.window_switcher.no_windows"))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            } else {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.fixed(Self.tileSize.width), spacing: Self.spacing),
                        count: layout.columns),
                    spacing: Self.spacing
                ) {
                    ForEach(Array(model.windows.enumerated()), id: \.element.id) { index, window in
                        tile(window, selected: index == model.selectedIndex)
                    }
                }
            }
        }
        // The fixed frame centers the grid, which is exactly `outerPadding` narrower
        // and shorter than the panel — that is what makes `gridOrigin` correct.
        .frame(width: size.width, height: size.height)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func tile(_ window: SwitcherWindow, selected: Bool) -> some View {
        VStack(spacing: Self.tileInset) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.06))
                thumbnail(for: window)
                if model.thumbnails[window.id] != nil {
                    // Badge only alongside a real snapshot — the fallback tile is
                    // already an oversized version of this same icon.
                    icon(for: window)
                        .frame(width: 20, height: 20)
                        .padding(4)
                }
            }
            .frame(width: Self.thumbWidth, height: Self.thumbHeight)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Text(window.title.isEmpty ? window.ownerName : window.title)
                .font(.system(size: 11))
                .foregroundColor(selected ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: Self.thumbWidth, height: Self.captionHeight)
        }
        .padding(Self.tileInset)
        .frame(width: Self.tileSize.width, height: Self.tileSize.height)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selected ? Color.accentColor.opacity(0.25) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    selected ? Color.accentColor : Color(nsColor: .separatorColor),
                    lineWidth: selected ? 3 : 1)
        )
    }

    /// The captured snapshot, or a large centered app icon.
    ///
    /// The icon path is not an error state — it is the permanent appearance without
    /// Screen Recording permission, so it is sized to look like a deliberate design
    /// rather than a failed image load.
    @ViewBuilder
    private func thumbnail(for window: SwitcherWindow) -> some View {
        if let image = model.thumbnails[window.id] {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            icon(for: window)
                .frame(width: 64, height: 64)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func icon(for window: SwitcherWindow) -> some View {
        if let appIcon = NSRunningApplication(processIdentifier: window.pid)?.icon {
            Image(nsImage: appIcon)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "macwindow")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundColor(.secondary)
        }
    }
}
