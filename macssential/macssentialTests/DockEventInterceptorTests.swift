import XCTest
@testable import macssential

final class DockEventInterceptorTests: XCTestCase {

    // MARK: - Test 1: isInDockTriggerZone returns true when mouse is within trigger zone

    func testIsInDockTriggerZoneReturnsTrueAtBottomEdge() {
        // Screen at origin (0, 0) with size 1920x1080 (NS coordinates: bottom=0, top=1080)
        let screenFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        // Mouse at Y=2, which is within 5px of bottom edge (minY=0)
        let mouseLocation = NSPoint(x: 960, y: 2)
        XCTAssertTrue(
            DockEventInterceptor.isInDockTriggerZone(
                mouseLocation: mouseLocation,
                screenFrame: screenFrame,
                triggerHeight: 5.0
            ),
            "Mouse at Y=2 should be within trigger zone (bottom edge + 5px)"
        )
    }

    // MARK: - Test 2: isInDockTriggerZone returns false above trigger zone

    func testIsInDockTriggerZoneReturnsFalseAboveZone() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        // Mouse at Y=100, well above trigger zone
        let mouseLocation = NSPoint(x: 960, y: 100)
        XCTAssertFalse(
            DockEventInterceptor.isInDockTriggerZone(
                mouseLocation: mouseLocation,
                screenFrame: screenFrame,
                triggerHeight: 5.0
            ),
            "Mouse at Y=100 should NOT be in trigger zone"
        )
    }

    // MARK: - Test 3: isInDockTriggerZone returns false outside horizontal bounds

    func testIsInDockTriggerZoneReturnsFalseOutsideHorizontalBounds() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        // Mouse at X=-10 (left of screen), Y=2 (within vertical trigger zone)
        let mouseLocation = NSPoint(x: -10, y: 2)
        XCTAssertFalse(
            DockEventInterceptor.isInDockTriggerZone(
                mouseLocation: mouseLocation,
                screenFrame: screenFrame,
                triggerHeight: 5.0
            ),
            "Mouse outside horizontal bounds should NOT be in trigger zone"
        )

        // Mouse at X=1930 (right of screen), Y=2
        let mouseLocationRight = NSPoint(x: 1930, y: 2)
        XCTAssertFalse(
            DockEventInterceptor.isInDockTriggerZone(
                mouseLocation: mouseLocationRight,
                screenFrame: screenFrame,
                triggerHeight: 5.0
            ),
            "Mouse right of screen should NOT be in trigger zone"
        )
    }

    // MARK: - Test 4: cgPointToNSPoint coordinate conversion

    func testCGPointToNSPointConversion() {
        // This test uses the actual primary screen height, which is environment-dependent.
        // We test the static method which uses NSScreen.screens.first.
        guard let primaryScreen = NSScreen.screens.first else {
            XCTFail("No primary screen available in test environment")
            return
        }
        let primaryHeight = primaryScreen.frame.height

        // CG (0, 0) is top-left corner -> NS should be (0, primaryHeight)
        let nsPoint = DockEventInterceptor.cgPointToNSPoint(CGPoint(x: 0, y: 0))
        XCTAssertEqual(nsPoint.x, 0, accuracy: 0.01, "X should be unchanged")
        XCTAssertEqual(nsPoint.y, primaryHeight, accuracy: 0.01, "CG Y=0 (top) should map to NS Y=primaryHeight")

        // CG (100, primaryHeight) is bottom-left -> NS should be (100, 0)
        let nsPointBottom = DockEventInterceptor.cgPointToNSPoint(CGPoint(x: 100, y: primaryHeight))
        XCTAssertEqual(nsPointBottom.x, 100, accuracy: 0.01)
        XCTAssertEqual(nsPointBottom.y, 0, accuracy: 0.01, "CG Y=primaryHeight (bottom) should map to NS Y=0")
    }

    // MARK: - Test 5: Trigger zone at boundary values

    func testTriggerZoneExactBoundary() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        // Exactly at triggerHeight boundary (Y=5.0 with triggerHeight=5.0)
        let mouseAtBoundary = NSPoint(x: 960, y: 5.0)
        XCTAssertTrue(
            DockEventInterceptor.isInDockTriggerZone(
                mouseLocation: mouseAtBoundary,
                screenFrame: screenFrame,
                triggerHeight: 5.0
            ),
            "Mouse at exactly triggerHeight should be IN trigger zone (inclusive)"
        )

        // Just above boundary (Y=5.01)
        let mouseAboveBoundary = NSPoint(x: 960, y: 5.01)
        XCTAssertFalse(
            DockEventInterceptor.isInDockTriggerZone(
                mouseLocation: mouseAboveBoundary,
                screenFrame: screenFrame,
                triggerHeight: 5.0
            ),
            "Mouse just above triggerHeight should NOT be in trigger zone"
        )
    }

    // MARK: - Test 6: Trigger zone with offset screen (multi-monitor)

    func testTriggerZoneWithOffsetScreen() {
        // Second screen positioned to the right and below primary
        let screenFrame = CGRect(x: 1920, y: -200, width: 2560, height: 1440)

        // Mouse at bottom edge of this screen (minY = -200)
        let mouseAtBottom = NSPoint(x: 3000, y: -198)
        XCTAssertTrue(
            DockEventInterceptor.isInDockTriggerZone(
                mouseLocation: mouseAtBottom,
                screenFrame: screenFrame,
                triggerHeight: 5.0
            ),
            "Mouse near bottom of offset screen should be in trigger zone"
        )

        // Mouse well above bottom
        let mouseAbove = NSPoint(x: 3000, y: 500)
        XCTAssertFalse(
            DockEventInterceptor.isInDockTriggerZone(
                mouseLocation: mouseAbove,
                screenFrame: screenFrame,
                triggerHeight: 5.0
            ),
            "Mouse well above bottom should NOT be in trigger zone"
        )
    }

    // MARK: - Test 7: Default trigger height is 5.0

    func testDefaultTriggerHeight() {
        XCTAssertEqual(
            DockEventInterceptor.triggerHeight, 5.0,
            "Default trigger height should be 5.0 pixels"
        )
    }

    // MARK: - Test 8: start() and stop() lifecycle (graceful without permission)

    func testStartStopLifecycle() {
        let interceptor = DockEventInterceptor()
        XCTAssertFalse(interceptor.isRunning, "Should not be running initially")

        // start() will fail without Accessibility permission in test env -- should not crash
        interceptor.start(targetDisplayID: CGMainDisplayID())
        // isRunning may be false (no permission) or true (has permission) -- either is valid

        // stop() should always be safe
        interceptor.stop()
        XCTAssertFalse(interceptor.isRunning, "Should not be running after stop()")

        // Double-stop should be safe
        interceptor.stop()
        XCTAssertFalse(interceptor.isRunning, "Double-stop should not crash")
    }

    // MARK: - Test 9: shouldBlockAtPointWithFlags with modifier flag returns false (bypass)

    func testModifierFlagBypassAllowsEvent() {
        let interceptor = DockEventInterceptor()
        interceptor.activeModifierMask = .maskAlternate // Option key

        // Point in a non-target screen's trigger zone
        // Even if this would normally be blocked, modifier key should bypass
        let screenFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        // Use a point at the bottom edge (trigger zone) in CG coordinates
        guard let primaryScreen = NSScreen.screens.first else { return }
        let cgBottomY = primaryScreen.frame.height // CG Y at NS bottom
        let cgPoint = CGPoint(x: 960, y: cgBottomY - 2)

        // With modifier flag present: should NOT block (bypass)
        let resultWithModifier = interceptor.shouldBlockAtPointWithFlags(
            cgPoint: cgPoint, flags: .maskAlternate
        )
        XCTAssertFalse(resultWithModifier,
                        "Event should pass through when modifier key is held")
    }

    // MARK: - Test 10: shouldBlockAtPointWithFlags without modifier blocks in trigger zone

    func testNoModifierFlagBlocksInTriggerZone() {
        let interceptor = DockEventInterceptor()
        interceptor.activeModifierMask = .maskAlternate
        // Set target to a non-existent display so all real screens are "non-target"
        interceptor.targetDisplayID = 99999

        // Use the actual primary screen's bottom edge
        guard let primaryScreen = NSScreen.screens.first else { return }
        let cgBottomY = primaryScreen.frame.height
        let cgPoint = CGPoint(x: primaryScreen.frame.midX, y: cgBottomY - 2)

        // Without modifier flag: should block (point in trigger zone of non-target screen)
        let resultWithoutModifier = interceptor.shouldBlockAtPointWithFlags(
            cgPoint: cgPoint, flags: CGEventFlags(rawValue: 0)
        )
        XCTAssertTrue(resultWithoutModifier,
                       "Event should be blocked when no modifier key and in trigger zone of non-target screen")
    }

    // MARK: - Test 11: isPaused state after pause/resume

    func testIsPausedStateAfterPauseResume() {
        let interceptor = DockEventInterceptor()
        XCTAssertFalse(interceptor.isPaused, "Should not be paused initially")

        // Without a running event tap, pause should be a no-op (guard checks eventTap)
        interceptor.pause()
        // isPaused stays false because eventTap is nil
        XCTAssertFalse(interceptor.isPaused,
                        "pause() on non-running interceptor should not set isPaused")

        // Start (may fail without accessibility, but we test the state machine)
        interceptor.start(targetDisplayID: CGMainDisplayID())
        if interceptor.isRunning {
            interceptor.pause()
            XCTAssertTrue(interceptor.isPaused, "Should be paused after pause()")

            interceptor.resume()
            XCTAssertFalse(interceptor.isPaused, "Should not be paused after resume()")
        }

        // stop() should reset isPaused
        interceptor.stop()
        XCTAssertFalse(interceptor.isPaused, "stop() should reset isPaused to false")
    }
}
