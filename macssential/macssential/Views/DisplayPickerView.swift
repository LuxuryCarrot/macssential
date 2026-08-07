import SwiftUI
import CoreGraphics

// MARK: - DisplayInfo Model

struct DisplayInfo: Identifiable, Sendable {
    let id: CGDirectDisplayID
    let frame: CGRect
    let name: String
    let hasDock: Bool

    static func from(screen: NSScreen) -> DisplayInfo? {
        guard let displayID = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? CGDirectDisplayID else { return nil }

        let frameDiff = screen.frame.height - screen.visibleFrame.height
            - (screen.visibleFrame.origin.y - screen.frame.origin.y)
        let hasDock = frameDiff > 0

        return DisplayInfo(
            id: displayID,
            frame: screen.frame,
            name: screen.localizedName,
            hasDock: hasDock
        )
    }
}

// MARK: - Layout Calculator (pure, testable)

struct DisplayLayoutCalculator {
    static func calculateProportionalLayout(
        displays: [DisplayInfo],
        maxWidth: CGFloat = 228,
        maxHeight: CGFloat = 120
    ) -> [(display: DisplayInfo, rect: CGRect)] {
        guard !displays.isEmpty else { return [] }

        // Bounding box of all screens
        let union = displays.reduce(CGRect.null) { $0.union($1.frame) }
        guard !union.isNull && union.width > 0 && union.height > 0 else { return [] }

        // Scale to fit within maxWidth x maxHeight, maintaining aspect ratio
        let scaleX = maxWidth / union.width
        let scaleY = maxHeight / union.height
        let scale = min(scaleX, scaleY)

        let scaledTotalWidth = union.width * scale
        let scaledTotalHeight = union.height * scale
        // Center horizontally
        let offsetX = (maxWidth - scaledTotalWidth) / 2

        return displays.map { display in
            let rect = CGRect(
                x: offsetX + (display.frame.origin.x - union.origin.x) * scale,
                // Flip Y: NSScreen bottom-left origin -> SwiftUI top-left origin
                y: scaledTotalHeight - (display.frame.origin.y - union.origin.y + display.frame.height) * scale,
                width: display.frame.width * scale,
                height: display.frame.height * scale
            )
            return (display, rect)
        }
    }
}

// MARK: - Status Banner View

private struct StatusBannerView: View {
    let message: String

    /// Determines the appropriate SF Symbol icon based on message content.
    private var iconName: String {
        message.contains("Paused") ? "pause.circle" : "display.trianglebadge.exclamationmark"
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
                .font(.system(size: 10))
                .foregroundColor(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(.caption)
                .foregroundColor(.primary)
                .lineLimit(2)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(4)
        .accessibilityLabel(message)
    }
}

// MARK: - DisplayPickerView

struct DisplayPickerView: View {
    @Binding var selectedDisplayID: CGDirectDisplayID
    var isEnabled: Bool = true
    var statusMessage: String? = nil
    var onStatusDismiss: (() -> Void)? = nil
    var isAutoPaused: Bool = false

    @State private var displays: [DisplayInfo] = []
    @State private var statusDismissWorkItem: DispatchWorkItem?

    private static let monitorKey = "com.macssential.module.dock-anchor.monitor"

    /// Whether the display picker should be interactive (not disabled and not auto-paused).
    private var isInteractive: Bool {
        isEnabled && !isAutoPaused
    }

    var body: some View {
        let layout = DisplayLayoutCalculator.calculateProportionalLayout(displays: displays)
        let containerHeight = layout.isEmpty ? 60 : layout.reduce(CGFloat(0)) { max($0, $1.rect.maxY) } + 24

        VStack(spacing: 4) {
            // Status banner (above monitor rectangles)
            if let message = statusMessage {
                StatusBannerView(message: message)
                    .onAppear {
                        scheduleStatusDismiss()
                    }
            }

            // Display picker area
            ZStack(alignment: .topLeading) {
                // Background
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)

                // Monitor rectangles
                ForEach(displays) { display in
                    if let entry = layout.first(where: { $0.display.id == display.id }) {
                        monitorView(display: display, rect: entry.rect)
                    }
                }
            }
            .frame(width: 228, height: containerHeight)
        }
        .opacity(isInteractive ? 1.0 : 0.5)
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .accessibilityElement(children: isAutoPaused ? .ignore : .contain)
        .accessibilityLabel(isAutoPaused ? "Display picker, paused, single monitor detected" : "Display picker")
        .onAppear {
            loadDisplays()
            if selectedDisplayID == 0 {
                selectedDisplayID = CGMainDisplayID()
                persistSelection()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            loadDisplays()
        }
    }

    @ViewBuilder
    private func monitorView(display: DisplayInfo, rect: CGRect) -> some View {
        let isSelected = display.id == selectedDisplayID

        VStack(spacing: 2) {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(monitorFill(isSelected: isSelected))

                RoundedRectangle(cornerRadius: 4)
                    .stroke(monitorStroke(isSelected: isSelected), lineWidth: isSelected ? 2 : 1)

                if isSelected && isInteractive {
                    Image(systemName: "star.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.accentColor)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: rect.width - 4, height: rect.height - 16)

            Text(display.name)
                .font(.caption2)
                .foregroundColor(.primary)
                .lineLimit(1)
        }
        .position(x: rect.midX, y: rect.midY)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(display.name), \(isSelected ? "selected" : "not selected")")
        .accessibilityAddTraits(isSelected && !isAutoPaused ? [.isButton, .isSelected] : (isAutoPaused ? [] : .isButton))
        .onTapGesture {
            guard isInteractive else { return }
            selectedDisplayID = display.id
            persistSelection()
            dismissStatus()
        }
    }

    private func monitorFill(isSelected: Bool) -> some ShapeStyle {
        if !isInteractive {
            return AnyShapeStyle(.tertiary.opacity(0.2))
        }
        if isSelected {
            return AnyShapeStyle(Color.accentColor.opacity(0.15))
        }
        return AnyShapeStyle(.secondary.opacity(0.15))
    }

    private func monitorStroke(isSelected: Bool) -> some ShapeStyle {
        if !isInteractive {
            return AnyShapeStyle(.tertiary.opacity(0.3))
        }
        if isSelected {
            return AnyShapeStyle(Color.accentColor)
        }
        return AnyShapeStyle(.secondary.opacity(0.3))
    }

    private func loadDisplays() {
        displays = NSScreen.screens.compactMap { DisplayInfo.from(screen: $0) }
    }

    private func persistSelection() {
        UserDefaults.standard.set(selectedDisplayID, forKey: Self.monitorKey)
    }

    // MARK: - Status Banner Auto-Dismiss

    private func scheduleStatusDismiss() {
        statusDismissWorkItem?.cancel()
        let workItem = DispatchWorkItem { [onStatusDismiss] in
            onStatusDismiss?()
        }
        statusDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: workItem)
    }

    private func dismissStatus() {
        statusDismissWorkItem?.cancel()
        onStatusDismiss?()
    }
}
