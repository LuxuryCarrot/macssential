import XCTest
@testable import macssential

/// Pure-logic coverage for the Window Switcher (QUICK-F4Y-01..04).
/// Nothing here touches Accessibility, AppKit, or a real CGEventTap — the engine
/// is deliberately UI-free so the switching rules can be proven off the run loop.
final class WindowSwitcherEngineTests: XCTestCase {

    private func makeWindow(
        pid: pid_t = 100,
        owner: String = "Safari",
        title: String = "Window",
        axIndex: Int = 0,
        zOrder: Int = 0,
        minimized: Bool = false
    ) -> SwitcherWindow {
        SwitcherWindow(pid: pid, ownerName: owner, title: title,
                       axIndex: axIndex, zOrder: zOrder, isMinimized: minimized)
    }

    // MARK: - filterAndOrder (QUICK-F4Y-01)

    func testEmptyInputYieldsEmptyOutput() {
        XCTAssertTrue(WindowSwitcherEngine.filterAndOrder([], excludingPID: 1).isEmpty,
            "No raw windows must produce no switchable windows")
    }

    func testBlankTitlesAreDropped() {
        let raw = [
            makeWindow(title: "Real Window", axIndex: 0),
            makeWindow(title: "", axIndex: 1),
            makeWindow(title: "   ", axIndex: 2),
            makeWindow(title: "\n\t", axIndex: 3)
        ]
        let result = WindowSwitcherEngine.filterAndOrder(raw, excludingPID: 1)
        XCTAssertEqual(result.count, 1,
            "Untitled windows (empty or whitespace-only titles) are not user-switchable and must be dropped")
        XCTAssertEqual(result.first?.title, "Real Window")
    }

    func testOwnProcessWindowsAreDropped() {
        let raw = [
            makeWindow(pid: 100, title: "Other App Window"),
            makeWindow(pid: 999, owner: "macssential", title: "macssential Panel")
        ]
        let result = WindowSwitcherEngine.filterAndOrder(raw, excludingPID: 999)
        XCTAssertEqual(result.count, 1, "The switcher must never offer its own windows")
        XCTAssertEqual(result.first?.pid, 100)
    }

    func testSystemOwnersAreDropped() {
        // These processes publish on-screen windows but are chrome, not user windows.
        let systemOwners = ["Window Server", "Dock", "Control Center",
                            "Notification Centre", "Notification Center",
                            "Spotlight", "SystemUIServer"]
        var raw = [makeWindow(pid: 100, owner: "Safari", title: "Apple")]
        for (i, owner) in systemOwners.enumerated() {
            raw.append(makeWindow(pid: pid_t(200 + i), owner: owner, title: "\(owner) surface"))
        }
        let result = WindowSwitcherEngine.filterAndOrder(raw, excludingPID: 1)
        XCTAssertEqual(result.count, 1,
            "Every system UI owner must be filtered out; only Safari remains")
        XCTAssertEqual(result.first?.ownerName, "Safari")
    }

    func testMinimizedWindowsAreDropped() {
        let raw = [
            makeWindow(title: "Visible", axIndex: 0, minimized: false),
            makeWindow(title: "In the Dock", axIndex: 1, minimized: true)
        ]
        let result = WindowSwitcherEngine.filterAndOrder(raw, excludingPID: 1)
        XCTAssertEqual(result.count, 1,
            "Minimized windows are not raise-able targets and must be dropped")
        XCTAssertEqual(result.first?.title, "Visible")
    }

    func testOutputIsSortedByZOrderAscending() {
        let raw = [
            makeWindow(pid: 3, title: "Back", axIndex: 0, zOrder: 9),
            makeWindow(pid: 1, title: "Front", axIndex: 0, zOrder: 0),
            makeWindow(pid: 2, title: "Middle", axIndex: 0, zOrder: 4)
        ]
        let result = WindowSwitcherEngine.filterAndOrder(raw, excludingPID: 999)
        XCTAssertEqual(result.map(\.title), ["Front", "Middle", "Back"],
            "zOrder 0 is frontmost, so ordering must be ascending by zOrder")
    }

    func testEqualZOrderKeepsInputOrder() {
        // Windows of the same app share a zOrder; AX returns them front-to-back,
        // so the sort must be stable to preserve that within-app order.
        let raw = [
            makeWindow(pid: 5, title: "First", axIndex: 0, zOrder: 2),
            makeWindow(pid: 5, title: "Second", axIndex: 1, zOrder: 2),
            makeWindow(pid: 5, title: "Third", axIndex: 2, zOrder: 2)
        ]
        let result = WindowSwitcherEngine.filterAndOrder(raw, excludingPID: 999)
        XCTAssertEqual(result.map(\.title), ["First", "Second", "Third"],
            "Ties on zOrder must keep discovery (AX) order — the sort must be stable")
    }

    func testIdentityIsPidAndAXIndex() {
        let window = makeWindow(pid: 42, axIndex: 3)
        XCTAssertEqual(window.id, "42:3",
            "Identity is composed from pid and AX window index so SwiftUI rows stay stable")
    }

    // MARK: - nextIndex cycling (QUICK-F4Y-02)

    func testForwardCyclingWraps() {
        XCTAssertEqual(WindowSwitcherEngine.nextIndex(current: 0, count: 3, backward: false), 1)
        XCTAssertEqual(WindowSwitcherEngine.nextIndex(current: 1, count: 3, backward: false), 2)
        XCTAssertEqual(WindowSwitcherEngine.nextIndex(current: 2, count: 3, backward: false), 0,
            "Forward past the last window must wrap to the first")
    }

    func testBackwardCyclingWraps() {
        XCTAssertEqual(WindowSwitcherEngine.nextIndex(current: 0, count: 3, backward: true), 2,
            "Backward before the first window must wrap to the last")
        XCTAssertEqual(WindowSwitcherEngine.nextIndex(current: 1, count: 3, backward: true), 0)
        XCTAssertEqual(WindowSwitcherEngine.nextIndex(current: 2, count: 3, backward: true), 1)
    }

    func testCyclingWithSingleWindowStaysPut() {
        XCTAssertEqual(WindowSwitcherEngine.nextIndex(current: 0, count: 1, backward: false), 0)
        XCTAssertEqual(WindowSwitcherEngine.nextIndex(current: 0, count: 1, backward: true), 0)
    }

    func testCyclingWithNoWindowsIsSafe() {
        // Guards against modulo-by-zero when Cmd+Tab is pressed with nothing switchable.
        XCTAssertEqual(WindowSwitcherEngine.nextIndex(current: 0, count: 0, backward: false), 0)
        XCTAssertEqual(WindowSwitcherEngine.nextIndex(current: 5, count: 0, backward: true), 0)
    }

    // MARK: - SwitcherSession state machine (QUICK-F4Y-03)

    private func threeWindows() -> [SwitcherWindow] {
        [makeWindow(pid: 1, owner: "A", title: "A1", axIndex: 0, zOrder: 0),
         makeWindow(pid: 2, owner: "B", title: "B1", axIndex: 0, zOrder: 1),
         makeWindow(pid: 3, owner: "C", title: "C1", axIndex: 0, zOrder: 2)]
    }

    func testFreshSessionIsInactiveAndCommitsNothing() {
        let session = SwitcherSession()
        XCTAssertFalse(session.isActive, "A session only becomes active on Cmd+Tab")
        XCTAssertNil(session.commit(), "Committing an inactive session must raise nothing")
    }

    func testBeginSelectsPreviousWindow() {
        let session = SwitcherSession()
        session.beginPending(backward: false)
        session.begin(windows: threeWindows())
        XCTAssertTrue(session.isActive)
        XCTAssertEqual(session.selectedIndex, 1,
            "Cmd+Tab must land on the previously used window (index 1), matching native muscle memory")
    }

    func testBeginWithSingleWindowSelectsIt() {
        let session = SwitcherSession()
        session.beginPending(backward: false)
        session.begin(windows: [makeWindow(title: "Only")])
        XCTAssertEqual(session.selectedIndex, 0,
            "With one switchable window there is nothing to step to")
    }

    func testBackwardInitialPressSelectsLastWindow() {
        let session = SwitcherSession()
        session.beginPending(backward: true)
        session.begin(windows: threeWindows())
        XCTAssertEqual(session.selectedIndex, 2,
            "Cmd+Shift+Tab as the opening press must land on the last window")
    }

    func testAdvanceBeforeListArrivesIsQueued() {
        // The event tap callback must return in microseconds, so AX enumeration is
        // deferred to the main queue. Taps that land in that window must not be lost.
        let session = SwitcherSession()
        session.beginPending(backward: false)
        session.advance(backward: false)
        XCTAssertTrue(session.windows.isEmpty, "The list has not arrived yet")

        session.begin(windows: threeWindows())
        XCTAssertEqual(session.selectedIndex, 2,
            "The queued Tab must be replayed once the window list is delivered (1 → 2)")
    }

    func testQueuedBackwardStepsAreReplayed() {
        let session = SwitcherSession()
        session.beginPending(backward: false)
        session.advance(backward: true)
        session.begin(windows: threeWindows())
        XCTAssertEqual(session.selectedIndex, 0,
            "A queued Shift+Tab must be replayed backward from the default landing index (1 → 0)")
    }

    func testAdvanceAfterListMovesSelection() {
        let session = SwitcherSession()
        session.beginPending(backward: false)
        session.begin(windows: threeWindows())
        session.advance(backward: false)
        XCTAssertEqual(session.selectedIndex, 2)
        session.advance(backward: false)
        XCTAssertEqual(session.selectedIndex, 0, "Advancing past the end wraps")
        session.advance(backward: true)
        XCTAssertEqual(session.selectedIndex, 2, "Shift+Tab steps backward and wraps")
    }

    func testBeginOnActiveSessionDoesNotResetSelection() {
        let session = SwitcherSession()
        session.beginPending(backward: false)
        session.begin(windows: threeWindows())
        session.advance(backward: false)
        XCTAssertEqual(session.selectedIndex, 2)

        session.begin(windows: threeWindows())
        XCTAssertEqual(session.selectedIndex, 2,
            "A second begin() while the list is loaded must not throw away the user's cycling")
    }

    func testCancelDeactivatesAndCommitsNothing() {
        let session = SwitcherSession()
        session.beginPending(backward: false)
        session.begin(windows: threeWindows())
        session.cancel()
        XCTAssertFalse(session.isActive, "Esc must end the session")
        XCTAssertNil(session.commit(), "Esc must raise no window")
        XCTAssertTrue(session.windows.isEmpty)
    }

    func testCommitReturnsSelectedWindowAndDeactivates() {
        let session = SwitcherSession()
        session.beginPending(backward: false)
        let windows = threeWindows()
        session.begin(windows: windows)
        let target = session.commit()
        XCTAssertEqual(target, windows[1], "Releasing Cmd must raise the selected window")
        XCTAssertFalse(session.isActive, "Commit ends the session")
        XCTAssertNil(session.commit(), "A second commit must be a no-op")
    }

    func testCommitWithNoWindowsReturnsNil() {
        let session = SwitcherSession()
        session.beginPending(backward: false)
        session.begin(windows: [])
        XCTAssertNil(session.commit(),
            "Cmd+Tab with nothing switchable must end without raising anything")
    }

    // MARK: - select(index:) (QUICK-HGV-01)

    func testSelectMovesSelectionWhenActive() {
        let session = SwitcherSession()
        session.beginPending(backward: false)
        session.begin(windows: threeWindows())
        session.select(index: 2)
        XCTAssertEqual(session.selectedIndex, 2,
            "Mouse hover must move the same selection state that Tab drives")
    }

    func testSelectIgnoresOutOfRangeIndex() {
        let session = SwitcherSession()
        session.beginPending(backward: false)
        session.begin(windows: threeWindows())
        session.select(index: 99)
        session.select(index: -1)
        XCTAssertEqual(session.selectedIndex, 1,
            "An out-of-range index (stale hover after the list shrank) must be ignored")
    }

    func testSelectIsNoOpWhenSessionInactive() {
        let session = SwitcherSession()
        session.select(index: 1)
        XCTAssertEqual(session.selectedIndex, 0,
            "Hover outside a live session must not fabricate a selection")
        XCTAssertFalse(session.isActive)
    }

    // MARK: - gridLayout (QUICK-HGV-01)

    func testGridLayoutOfEmptyListIsZeroByZero() {
        let layout = WindowSwitcherEngine.gridLayout(count: 0, maxColumns: 5)
        XCTAssertEqual(layout, WindowSwitcherEngine.GridLayout(columns: 0, rows: 0),
            "An empty grid must report zero columns so no downstream divide-by-zero is possible")
    }

    func testGridLayoutFitsSingleRowUpToMaxColumns() {
        for count in 1...5 {
            let layout = WindowSwitcherEngine.gridLayout(count: count, maxColumns: 5)
            XCTAssertEqual(layout, WindowSwitcherEngine.GridLayout(columns: count, rows: 1),
                "\(count) windows fit on one row and must not pad out to the column maximum")
        }
    }

    func testGridLayoutWrapsToMultipleRows() {
        XCTAssertEqual(WindowSwitcherEngine.gridLayout(count: 7, maxColumns: 5),
                       WindowSwitcherEngine.GridLayout(columns: 5, rows: 2),
            "7 windows over 5 columns is 2 rows (the second partially filled)")
        XCTAssertEqual(WindowSwitcherEngine.gridLayout(count: 10, maxColumns: 5),
                       WindowSwitcherEngine.GridLayout(columns: 5, rows: 2))
        XCTAssertEqual(WindowSwitcherEngine.gridLayout(count: 11, maxColumns: 5),
                       WindowSwitcherEngine.GridLayout(columns: 5, rows: 3))
    }

    func testGridLayoutWithNonPositiveMaxColumnsIsEmpty() {
        XCTAssertEqual(WindowSwitcherEngine.gridLayout(count: 4, maxColumns: 0),
                       WindowSwitcherEngine.GridLayout(columns: 0, rows: 0),
            "A degenerate column budget must degrade to an empty layout, never trap")
    }

    // MARK: - tileIndex (QUICK-HGV-01)

    private static let tileSize = CGSize(width: 160, height: 116)
    private static let spacing: CGFloat = 12
    private static let gridOrigin = CGPoint(x: 16, y: 16)

    private func hitTest(_ point: CGPoint, count: Int, columns: Int, rows: Int) -> Int? {
        WindowSwitcherEngine.tileIndex(
            at: point,
            gridOrigin: Self.gridOrigin,
            tileSize: Self.tileSize,
            spacing: Self.spacing,
            layout: WindowSwitcherEngine.GridLayout(columns: columns, rows: rows),
            count: count
        )
    }

    func testTileIndexInsideFirstTile() {
        XCTAssertEqual(hitTest(CGPoint(x: 20, y: 20), count: 7, columns: 5, rows: 2), 0,
            "A point just inside the top-left tile is index 0")
        XCTAssertEqual(hitTest(CGPoint(x: 100, y: 80), count: 7, columns: 5, rows: 2), 0)
    }

    func testTileIndexInSecondRowFirstColumn() {
        // Second row starts one tile height + one spacing below the grid origin.
        let y = Self.gridOrigin.y + Self.tileSize.height + Self.spacing + 10
        XCTAssertEqual(hitTest(CGPoint(x: 20, y: y), count: 7, columns: 5, rows: 2), 5,
            "The first tile of row 2 is index == columns")
    }

    func testTileIndexInSpacingGutterIsNil() {
        // Horizontal gutter between column 0 and column 1.
        let x = Self.gridOrigin.x + Self.tileSize.width + Self.spacing / 2
        XCTAssertNil(hitTest(CGPoint(x: x, y: 30), count: 7, columns: 5, rows: 2),
            "The gap between tiles selects nothing — hover must not flicker across it")

        // Vertical gutter between row 0 and row 1.
        let y = Self.gridOrigin.y + Self.tileSize.height + Self.spacing / 2
        XCTAssertNil(hitTest(CGPoint(x: 30, y: y), count: 7, columns: 5, rows: 2))
    }

    func testTileIndexOutsideGridIsNil() {
        XCTAssertNil(hitTest(CGPoint(x: 4, y: 30), count: 7, columns: 5, rows: 2),
            "Left of the grid origin is outside the grid")
        XCTAssertNil(hitTest(CGPoint(x: 30, y: 4), count: 7, columns: 5, rows: 2),
            "Above the grid origin is outside the grid")
        let farRight = Self.gridOrigin.x + 5 * (Self.tileSize.width + Self.spacing) + 20
        XCTAssertNil(hitTest(CGPoint(x: farRight, y: 30), count: 7, columns: 5, rows: 2),
            "Right of the last column is outside the grid")
        let farBelow = Self.gridOrigin.y + 2 * (Self.tileSize.height + Self.spacing) + 20
        XCTAssertNil(hitTest(CGPoint(x: 30, y: farBelow), count: 7, columns: 5, rows: 2),
            "Below the last row is outside the grid")
    }

    func testTileIndexOverPhantomTrailingCellIsNil() {
        // count 7 over 5 columns: row 1 has cells 5 and 6; cells 7, 8, 9 are phantom.
        let x = Self.gridOrigin.x + 2 * (Self.tileSize.width + Self.spacing) + 10
        let y = Self.gridOrigin.y + Self.tileSize.height + Self.spacing + 10
        XCTAssertNil(hitTest(CGPoint(x: x, y: y), count: 7, columns: 5, rows: 2),
            "An empty trailing cell in the last row must not resolve to a window")
    }

    func testTileIndexWithEmptyLayoutIsNil() {
        XCTAssertNil(hitTest(CGPoint(x: 20, y: 20), count: 0, columns: 0, rows: 0),
            "Hit-testing an empty grid must be safe")
    }

    // MARK: - shouldAttemptCapture (QUICK-HGV-02)

    func testCaptureOnlyWhenPermittedLiveAndUncaptured() {
        XCTAssertTrue(WindowSwitcherEngine.shouldAttemptCapture(
            hasPermission: true, sessionActive: true, alreadyCaptured: false))
    }

    func testCaptureSkippedWithoutScreenRecordingPermission() {
        XCTAssertFalse(WindowSwitcherEngine.shouldAttemptCapture(
            hasPermission: false, sessionActive: true, alreadyCaptured: false),
            "Without Screen Recording the switcher falls back to app icons and must not attempt capture")
    }

    func testCaptureSkippedWhenSessionEnded() {
        XCTAssertFalse(WindowSwitcherEngine.shouldAttemptCapture(
            hasPermission: true, sessionActive: false, alreadyCaptured: false),
            "A capture landing after Cmd release must be discarded, not applied")
    }

    func testCaptureSkippedWhenAlreadyCapturedThisSession() {
        XCTAssertFalse(WindowSwitcherEngine.shouldAttemptCapture(
            hasPermission: true, sessionActive: true, alreadyCaptured: true),
            "One snapshot per window per session — repeats would burn CPU while Tab repeats")
    }

    // MARK: - bestThumbnailMatch (QUICK-HGV-02)

    private func candidate(
        id: UInt32, pid: pid_t, title: String, size: CGSize
    ) -> WindowSwitcherEngine.ThumbnailCandidate {
        WindowSwitcherEngine.ThumbnailCandidate(
            windowID: id, pid: pid, title: title,
            frame: CGRect(origin: .zero, size: size))
    }

    func testThumbnailMatchPrefersExactTitle() {
        let window = makeWindow(pid: 100, title: "Inbox")
        let candidates = [
            candidate(id: 1, pid: 100, title: "Drafts", size: CGSize(width: 2000, height: 2000)),
            candidate(id: 2, pid: 100, title: "Inbox", size: CGSize(width: 100, height: 100)),
            candidate(id: 3, pid: 200, title: "Inbox", size: CGSize(width: 3000, height: 3000))
        ]
        XCTAssertEqual(
            WindowSwitcherEngine.bestThumbnailMatch(for: window, in: candidates)?.windowID, 2,
            "An exact pid+title match beats both a larger sibling and a same-title window of another app")
    }

    func testThumbnailMatchAcceptsSolePIDCandidate() {
        let window = makeWindow(pid: 100, title: "Untitled Document")
        let candidates = [
            candidate(id: 7, pid: 100, title: "", size: CGSize(width: 800, height: 600)),
            candidate(id: 8, pid: 999, title: "Untitled Document", size: CGSize(width: 900, height: 700))
        ]
        XCTAssertEqual(
            WindowSwitcherEngine.bestThumbnailMatch(for: window, in: candidates)?.windowID, 7,
            "ScreenCaptureKit withholds some titles; a single window of the right app is still the right window")
    }

    func testThumbnailMatchPrefersLargestUntitledCandidate() {
        let window = makeWindow(pid: 100, title: "Editor")
        let candidates = [
            candidate(id: 1, pid: 100, title: "", size: CGSize(width: 200, height: 100)),
            candidate(id: 2, pid: 100, title: "", size: CGSize(width: 1200, height: 800)),
            candidate(id: 3, pid: 100, title: "", size: CGSize(width: 400, height: 300))
        ]
        XCTAssertEqual(
            WindowSwitcherEngine.bestThumbnailMatch(for: window, in: candidates)?.windowID, 2,
            "With no title to disambiguate, the largest window is the likeliest real document window")
    }

    func testThumbnailMatchReturnsNilWithoutPIDMatch() {
        let window = makeWindow(pid: 100, title: "Inbox")
        let candidates = [
            candidate(id: 1, pid: 200, title: "Inbox", size: CGSize(width: 800, height: 600))
        ]
        XCTAssertNil(WindowSwitcherEngine.bestThumbnailMatch(for: window, in: candidates),
            "No window of that app is capturable — the tile keeps its app-icon fallback")
    }

    func testThumbnailMatchOfEmptyCandidateListIsNil() {
        XCTAssertNil(WindowSwitcherEngine.bestThumbnailMatch(for: makeWindow(), in: []))
    }

    // MARK: - Grid navigation (QUICK-I8L-01)

    // Every case below uses the same shape: 7 tiles across 5 columns, so the first
    // row holds 0...4 and the short final row holds 5 and 6.

    func testGridMoveRightContinuesIntoTheNextRow() {
        XCTAssertEqual(
            WindowSwitcherEngine.gridMove(current: 4, count: 7, columns: 5, direction: .right), 5,
            "Right at the end of a row continues onto the first tile of the next row, matching Tab")
    }

    func testGridMoveRightWrapsFromTheLastTile() {
        XCTAssertEqual(
            WindowSwitcherEngine.gridMove(current: 6, count: 7, columns: 5, direction: .right), 0,
            "Right on the final tile wraps to the first, exactly as Tab does")
    }

    func testGridMoveLeftStepsBackAcrossTheRowBoundary() {
        XCTAssertEqual(
            WindowSwitcherEngine.gridMove(current: 5, count: 7, columns: 5, direction: .left), 4)
    }

    func testGridMoveLeftWrapsFromTheFirstTile() {
        XCTAssertEqual(
            WindowSwitcherEngine.gridMove(current: 0, count: 7, columns: 5, direction: .left), 6,
            "Left on the first tile wraps to the last, exactly as Shift+Tab does")
    }

    func testGridMoveHorizontalAgreesWithTabCycling() {
        for index in 0..<7 {
            XCTAssertEqual(
                WindowSwitcherEngine.gridMove(current: index, count: 7, columns: 5, direction: .right),
                WindowSwitcherEngine.nextIndex(current: index, count: 7, backward: false),
                "Right must be indistinguishable from Tab so the two inputs cannot disagree")
            XCTAssertEqual(
                WindowSwitcherEngine.gridMove(current: index, count: 7, columns: 5, direction: .left),
                WindowSwitcherEngine.nextIndex(current: index, count: 7, backward: true),
                "Left must be indistinguishable from Shift+Tab")
        }
    }

    func testGridMoveDownMovesOneRow() {
        XCTAssertEqual(
            WindowSwitcherEngine.gridMove(current: 0, count: 7, columns: 5, direction: .down), 5)
    }

    func testGridMoveDownClampsToLastTileOfShortFinalRow() {
        XCTAssertEqual(
            WindowSwitcherEngine.gridMove(current: 2, count: 7, columns: 5, direction: .down), 6,
            "Column 2 has no tile in the short final row — clamp to the last tile rather than doing nothing")
    }

    func testGridMoveDownInLastRowStaysPut() {
        XCTAssertEqual(
            WindowSwitcherEngine.gridMove(current: 5, count: 7, columns: 5, direction: .down), 5,
            "Vertical moves clamp instead of wrapping, so a held Down cannot cycle forever")
        XCTAssertEqual(
            WindowSwitcherEngine.gridMove(current: 6, count: 7, columns: 5, direction: .down), 6)
    }

    func testGridMoveUpMovesOneRow() {
        XCTAssertEqual(
            WindowSwitcherEngine.gridMove(current: 5, count: 7, columns: 5, direction: .up), 0)
    }

    func testGridMoveUpInFirstRowStaysPut() {
        XCTAssertEqual(
            WindowSwitcherEngine.gridMove(current: 0, count: 7, columns: 5, direction: .up), 0)
        XCTAssertEqual(
            WindowSwitcherEngine.gridMove(current: 3, count: 7, columns: 5, direction: .up), 3,
            "Up from the first row must not wrap to the bottom")
    }

    func testGridMoveOnEmptyListReturnsZero() {
        for direction in [WindowSwitcherEngine.GridDirection.up, .down, .left, .right] {
            XCTAssertEqual(
                WindowSwitcherEngine.gridMove(current: 0, count: 0, columns: 5, direction: direction), 0,
                "An empty list must never trap on a modulo or index arithmetic")
        }
    }

    func testGridMoveWithoutColumnsIsANoOp() {
        for direction in [WindowSwitcherEngine.GridDirection.up, .down, .left, .right] {
            XCTAssertEqual(
                WindowSwitcherEngine.gridMove(current: 3, count: 7, columns: 0, direction: direction), 3,
                "A degenerate layout leaves the selection exactly where it was")
        }
    }

    func testGridMoveWithSingleWindowAlwaysStaysOnIt() {
        for direction in [WindowSwitcherEngine.GridDirection.up, .down, .left, .right] {
            XCTAssertEqual(
                WindowSwitcherEngine.gridMove(current: 0, count: 1, columns: 1, direction: direction), 0)
        }
    }

    // MARK: - Thumbnail cache rules (QUICK-I8L-02)

    func testCachedContentIsFreshBelowTTLOnly() {
        XCTAssertTrue(WindowSwitcherEngine.ThumbnailCacheRules.isFresh(age: 1.9, ttl: 2.0))
        XCTAssertFalse(WindowSwitcherEngine.ThumbnailCacheRules.isFresh(age: 2.0, ttl: 2.0),
            "At exactly the TTL the entry is stale — the boundary must not extend the window")
        XCTAssertFalse(WindowSwitcherEngine.ThumbnailCacheRules.isFresh(age: 5.0, ttl: 2.0))
    }

    func testRetainedIDsKeepsTheMostRecentUpToCapacity() {
        let order = ["e", "d", "c", "b", "a"] // most-recently-used first
        XCTAssertEqual(
            WindowSwitcherEngine.ThumbnailCacheRules.retainedIDs(
                order: order, liveIDs: Set(order), capacity: 3),
            ["e", "d", "c"],
            "The two least recently used entries are evicted and the survivors keep their order")
    }

    func testRetainedIDsDropsClosedWindowsBeforeLRUEviction() {
        let order = ["e", "d", "c", "b", "a"]
        XCTAssertEqual(
            WindowSwitcherEngine.ThumbnailCacheRules.retainedIDs(
                order: order, liveIDs: ["d", "b", "a"], capacity: 3),
            ["d", "b", "a"],
            "A recent entry whose window is gone is dropped first — its pixels must not linger")
    }

    func testRetainedIDsWithZeroCapacityKeepsNothing() {
        XCTAssertTrue(
            WindowSwitcherEngine.ThumbnailCacheRules.retainedIDs(
                order: ["a", "b"], liveIDs: ["a", "b"], capacity: 0).isEmpty)
    }

    func testServeCachedRequiresPermissionAndAnEntry() {
        XCTAssertTrue(WindowSwitcherEngine.ThumbnailCacheRules.shouldServeCached(
            hasPermission: true, hasEntry: true))
        XCTAssertFalse(WindowSwitcherEngine.ThumbnailCacheRules.shouldServeCached(
            hasPermission: false, hasEntry: true),
            "Permission revoked between sessions must blank the tiles, not replay old pixels")
        XCTAssertFalse(WindowSwitcherEngine.ThumbnailCacheRules.shouldServeCached(
            hasPermission: true, hasEntry: false))
    }
}
