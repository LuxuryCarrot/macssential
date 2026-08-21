import CoreGraphics
import Foundation

/// A single switchable window, flattened into a plain value type.
///
/// Deliberately holds NO `AXUIElement`: the element is re-resolved at activation
/// time (window lists shift while the overlay is open), and a value type keeps the
/// whole switching rule set unit-testable without Accessibility permission.
struct SwitcherWindow: Equatable, Identifiable {
    /// Composed from pid + AX window index — stable enough for SwiftUI row identity
    /// within a single switcher session, which is the only lifetime that matters.
    let id: String
    let pid: pid_t
    let ownerName: String
    let title: String
    /// Index in the owning app's `kAXWindowsAttribute` array, used to re-resolve
    /// the live element when the selection is committed.
    let axIndex: Int
    /// 0 = frontmost. Derived from the app's front-to-back order on screen.
    let zOrder: Int
    let isMinimized: Bool

    init(pid: pid_t, ownerName: String, title: String, axIndex: Int, zOrder: Int, isMinimized: Bool) {
        self.id = "\(pid):\(axIndex)"
        self.pid = pid
        self.ownerName = ownerName
        self.title = title
        self.axIndex = axIndex
        self.zOrder = zOrder
        self.isMinimized = isMinimized
    }
}

/// Pure switching rules: which windows are offered, in what order, and how the
/// selection moves. No AppKit, no Accessibility, no UI — everything here runs
/// (and is tested) off the run loop.
enum WindowSwitcherEngine {

    /// Processes that publish on-screen, titled windows which are system chrome
    /// rather than user windows. Raising these is either impossible or useless,
    /// so they never appear in the switcher.
    ///
    /// Both "Centre" and "Center" spellings are listed because the process's
    /// localized name follows the system region setting.
    static let excludedOwners: Set<String> = [
        "Window Server",
        "WindowServer",
        "Dock",
        "Control Center",
        "Control Centre",
        "Notification Center",
        "Notification Centre",
        "Spotlight",
        "SystemUIServer"
    ]

    /// Drops non-switchable entries and orders the rest front-to-back.
    ///
    /// - Parameter excludingPID: macssential's own pid. The switcher must never
    ///   offer its own overlay/panel as a target.
    static func filterAndOrder(_ raw: [SwitcherWindow], excludingPID: pid_t) -> [SwitcherWindow] {
        let kept = raw.filter { window in
            guard window.pid != excludingPID else { return false }
            guard !window.isMinimized else { return false }
            guard !excludedOwners.contains(window.ownerName) else { return false }
            // An untitled window cannot be labelled in the overlay and is almost
            // always an off-screen helper surface — drop it.
            guard !window.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            return true
        }

        // Swift's `sorted(by:)` is NOT documented as stable, and windows of the
        // same app legitimately share a zOrder. Sorting on (zOrder, discoveryIndex)
        // makes the tie-break explicit so within-app AX order (front-to-back) survives.
        return kept.enumerated()
            .sorted { lhs, rhs in
                lhs.element.zOrder == rhs.element.zOrder
                    ? lhs.offset < rhs.offset
                    : lhs.element.zOrder < rhs.element.zOrder
            }
            .map(\.element)
    }

    /// Moves a selection index one step, wrapping at both ends.
    /// Returns 0 for an empty list so callers never hit a modulo-by-zero trap.
    static func nextIndex(current: Int, count: Int, backward: Bool) -> Int {
        guard count > 0 else { return 0 }
        return backward
            ? (current - 1 + count) % count
            : (current + 1) % count
    }

    // MARK: - Grid Navigation

    /// One arrow-key step across the tile grid.
    enum GridDirection {
        case up, down, left, right
    }

    /// Moves the selection one tile in `direction` across a `columns`-wide grid.
    ///
    /// The wrap semantics are deliberately asymmetric:
    ///
    /// - **Horizontal wraps.** Right is `nextIndex(backward: false)` and Left is its
    ///   inverse, so Right at the end of a row continues onto the next row and Right
    ///   on the last tile returns to the first. Left/Right are therefore *exactly*
    ///   Tab/Shift+Tab, which means the two input methods can never disagree about
    ///   where the selection is, and it matches the row-continuation the grid draws.
    /// - **Vertical clamps.** Down from the last row stays put, and Up from the first
    ///   row stays put. Wrapping vertically would let a held arrow cycle the grid
    ///   forever with no visible end, and there is no "previous row" muscle memory to
    ///   honour the way there is for Tab. When the target row exists but is short
    ///   (the final row of a partially filled grid), Down clamps to the last tile
    ///   rather than refusing to move — the user asked to go down and there is a tile
    ///   down there, just not in that column.
    ///
    /// Degenerate inputs never trap: an empty list answers 0, and a zero-column
    /// layout leaves the selection untouched.
    static func gridMove(current: Int, count: Int, columns: Int, direction: GridDirection) -> Int {
        guard count > 0 else { return 0 }
        guard columns > 0 else { return current }

        switch direction {
        case .right:
            return nextIndex(current: current, count: count, backward: false)
        case .left:
            return nextIndex(current: current, count: count, backward: true)
        case .up:
            let target = current - columns
            return target >= 0 ? target : current
        case .down:
            let target = current + columns
            if target < count { return target }
            // No tile directly below. Clamp to the final tile unless the selection is
            // already in the last row, in which case there is nowhere further to go.
            let lastRowStart = ((count - 1) / columns) * columns
            return current >= lastRowStart ? current : count - 1
        }
    }

    // MARK: - Grid Geometry

    /// Shape of the tile grid: how many columns wide and how many rows tall.
    struct GridLayout: Equatable {
        let columns: Int
        let rows: Int
    }

    /// Chooses the grid shape for `count` tiles, capped at `maxColumns` per row.
    ///
    /// Returns a zero layout for an empty (or degenerate) input so every caller —
    /// the SwiftUI `LazyVGrid` column array and the AppKit hit-test alike — can use
    /// the result without a divide-by-zero guard of its own.
    static func gridLayout(count: Int, maxColumns: Int) -> GridLayout {
        guard count > 0, maxColumns > 0 else { return GridLayout(columns: 0, rows: 0) }
        let columns = min(count, maxColumns)
        // Integer ceiling: avoids Double rounding at exact multiples (10 / 5 must be 2, not 3).
        let rows = (count + columns - 1) / columns
        return GridLayout(columns: columns, rows: rows)
    }

    /// Resolves a point to the window index whose tile contains it, or nil.
    ///
    /// COORDINATE SPACE: top-left origin, y growing downward, matching how the grid
    /// reads visually (tile 0 top-left, filling left-to-right then top-to-bottom).
    /// AppKit's window space is bottom-left origin, so a caller coming from AppKit
    /// must flip y exactly once before calling this — doing the flip here as well
    /// would silently mirror the grid.
    ///
    /// Returns nil for three distinct misses, all of which must deselect nothing
    /// rather than clamp to a neighbour:
    /// - outside the grid rectangle entirely
    /// - inside an inter-tile gutter (`spacing`)
    /// - over a phantom trailing cell of the last, partially filled row
    static func tileIndex(
        at point: CGPoint,
        gridOrigin: CGPoint,
        tileSize: CGSize,
        spacing: CGFloat,
        layout: GridLayout,
        count: Int
    ) -> Int? {
        guard layout.columns > 0, layout.rows > 0, count > 0 else { return nil }
        guard tileSize.width > 0, tileSize.height > 0 else { return nil }

        let strideX = tileSize.width + spacing
        let strideY = tileSize.height + spacing
        let dx = point.x - gridOrigin.x
        let dy = point.y - gridOrigin.y
        guard dx >= 0, dy >= 0 else { return nil }

        let column = Int((dx / strideX).rounded(.down))
        let row = Int((dy / strideY).rounded(.down))
        guard column < layout.columns, row < layout.rows else { return nil }

        // Reject the gutter: the offset within a stride must land on the tile,
        // not on the `spacing` that trails it.
        guard dx - CGFloat(column) * strideX <= tileSize.width,
              dy - CGFloat(row) * strideY <= tileSize.height else { return nil }

        let index = row * layout.columns + column
        guard index < count else { return nil }
        return index
    }

    // MARK: - Thumbnail Rules

    /// Whether a window snapshot should be attempted right now.
    ///
    /// All three conditions are load-bearing: without Screen Recording permission the
    /// switcher shows app icons and must never touch the capture stack (that is what
    /// keeps the TCC prompt from firing); a capture request that outlives its session
    /// is wasted work on a dismissed overlay; and one snapshot per window per session
    /// keeps held-Tab repeats from re-capturing the same windows continuously.
    static func shouldAttemptCapture(
        hasPermission: Bool, sessionActive: Bool, alreadyCaptured: Bool
    ) -> Bool {
        hasPermission && sessionActive && !alreadyCaptured
    }

    /// Pure caching policy for the thumbnail service.
    ///
    /// The service itself is `@MainActor` and ScreenCaptureKit-bound, so none of it
    /// can run in a test. Every decision it makes about *what to keep* therefore
    /// lives here, where it is provable without Screen Recording permission.
    enum ThumbnailCacheRules {

        /// Whether a cached value may still be used. Stale at exactly `ttl`, so a
        /// boundary sample never silently extends the window.
        static func isFresh(age: TimeInterval, ttl: TimeInterval) -> Bool {
            age < ttl
        }

        /// The cache entries to KEEP, in order.
        ///
        /// - Parameter order: cached ids, most-recently-used first.
        /// - Parameter liveIDs: ids of windows that still exist.
        /// - Parameter capacity: hard ceiling on retained entries.
        ///
        /// Dead windows are dropped BEFORE any LRU decision, however recently they
        /// were captured: their pixels are both useless and the longest-lived
        /// privacy exposure in the cache (T-I8L-01). Only then is the remainder
        /// truncated to `capacity`.
        static func retainedIDs(order: [String], liveIDs: Set<String>, capacity: Int) -> [String] {
            guard capacity > 0 else { return [] }
            return Array(order.filter { liveIDs.contains($0) }.prefix(capacity))
        }

        /// Whether a previously captured image may be replayed into a tile.
        ///
        /// Gating the replay on the *current* permission answer means revoking Screen
        /// Recording between sessions blanks the tiles immediately rather than
        /// showing pixels the user has just withdrawn consent for.
        static func shouldServeCached(hasPermission: Bool, hasEntry: Bool) -> Bool {
            hasPermission && hasEntry
        }
    }

    /// A capturable window as reported by the capture stack, flattened to a value
    /// type so the matching rule is testable without Screen Recording permission.
    struct ThumbnailCandidate: Equatable {
        let windowID: UInt32
        let pid: pid_t
        let title: String
        let frame: CGRect
    }

    /// Pairs an Accessibility-sourced `SwitcherWindow` with the capture stack's view
    /// of the same window.
    ///
    /// The two APIs have no shared identifier — AX gives titles and an app-relative
    /// index, the capture stack gives a `CGWindowID` — so the match is heuristic:
    /// pid narrows the field, an exact title pins it, and otherwise the largest
    /// window of that app is the likeliest real document window (helper panels and
    /// toolbars are small). A wrong guess only shows a neighbouring window's
    /// thumbnail; the raise path never uses this result.
    static func bestThumbnailMatch(
        for window: SwitcherWindow, in candidates: [ThumbnailCandidate]
    ) -> ThumbnailCandidate? {
        let sameApp = candidates.filter { $0.pid == window.pid }
        guard !sameApp.isEmpty else { return nil }

        func area(_ candidate: ThumbnailCandidate) -> CGFloat {
            abs(candidate.frame.width * candidate.frame.height)
        }

        if !window.title.isEmpty {
            let exact = sameApp.filter { $0.title == window.title }
            if let best = exact.max(by: { area($0) < area($1) }) { return best }
        }
        return sameApp.max(by: { area($0) < area($1) })
    }
}

/// State machine for one Cmd-held switching episode.
///
/// Split from the module so the ordering/cycling behaviour can be proven without a
/// real event tap. Only ever driven from the main run loop (the tap callback and
/// the main-queue follow-ups), so it needs no internal locking.
final class SwitcherSession {

    private(set) var isActive = false
    private(set) var windows: [SwitcherWindow] = []
    private(set) var selectedIndex = 0

    /// Tab presses that arrived before the window list was available.
    ///
    /// The CGEventTap callback must return in microseconds — enumerating every
    /// app's AX windows there would risk `tapDisabledByTimeout`, which freezes
    /// keyboard input system-wide. Enumeration is therefore deferred to the main
    /// queue, and any Tab that lands in that gap is queued here and replayed once
    /// the list arrives, so no keystroke is silently swallowed.
    private var pendingSteps = 0

    init() {}

    /// Marks the session active with no list yet. Called synchronously from the
    /// event tap callback on the opening Cmd+Tab.
    ///
    /// `begin(windows:)` lands on index 1 — one step forward from the current
    /// window — which is the correct destination for a forward opening press.
    /// A backward opening press must instead land on the last window, which is
    /// two backward steps from index 1 (1 → 0 → count-1); hence -2.
    func beginPending(backward: Bool) {
        guard !isActive else { return }
        isActive = true
        windows = []
        selectedIndex = 0
        pendingSteps = backward ? -2 : 0
    }

    /// Delivers the enumerated window list. No-op once a list is loaded, so a
    /// late second delivery cannot discard the cycling the user has already done.
    func begin(windows: [SwitcherWindow]) {
        guard isActive else { return }
        guard self.windows.isEmpty else { return }
        guard !windows.isEmpty else { return }

        self.windows = windows
        // Land on the previously used window, matching native Cmd+Tab muscle memory.
        selectedIndex = windows.count > 1 ? 1 : 0

        let steps = pendingSteps
        pendingSteps = 0
        let backward = steps < 0
        for _ in 0..<abs(steps) {
            selectedIndex = WindowSwitcherEngine.nextIndex(
                current: selectedIndex, count: windows.count, backward: backward)
        }
    }

    /// One Tab (or Shift+Tab) press. Queued when the list has not arrived yet.
    func advance(backward: Bool) {
        guard isActive else { return }
        guard !windows.isEmpty else {
            pendingSteps += backward ? -1 : 1
            return
        }
        selectedIndex = WindowSwitcherEngine.nextIndex(
            current: selectedIndex, count: windows.count, backward: backward)
    }

    /// Mouse path: jump straight to a tile instead of stepping to it.
    ///
    /// Shares `selectedIndex` with `advance`, so hovering and then pressing Tab
    /// continues from the hovered tile rather than from where the keyboard left off.
    /// Silently ignores an out-of-range index: a hover can be delivered against a
    /// window list that has since shrunk.
    func select(index: Int) {
        guard isActive, windows.indices.contains(index) else { return }
        selectedIndex = index
    }

    /// Arrow path: one grid step in `direction`.
    ///
    /// Mutates the same `selectedIndex` as `advance` and `select`, so arrows, Tab and
    /// mouse hover are three inputs into one piece of state and can never disagree.
    ///
    /// Unlike Tab, an arrow arriving before the window list has loaded is dropped
    /// rather than queued: Tab means "one step from wherever I end up", which is
    /// replayable, while "one row down" has no meaning against a grid whose shape is
    /// not yet known.
    func move(_ direction: WindowSwitcherEngine.GridDirection, columns: Int) {
        guard isActive, !windows.isEmpty else { return }
        selectedIndex = WindowSwitcherEngine.gridMove(
            current: selectedIndex, count: windows.count, columns: columns, direction: direction)
    }

    /// Esc path: end the session without raising anything.
    func cancel() {
        isActive = false
        windows = []
        selectedIndex = 0
        pendingSteps = 0
    }

    /// Cmd-release path: returns the window to raise and ends the session.
    func commit() -> SwitcherWindow? {
        defer { cancel() }
        guard isActive, windows.indices.contains(selectedIndex) else { return nil }
        return windows[selectedIndex]
    }
}
