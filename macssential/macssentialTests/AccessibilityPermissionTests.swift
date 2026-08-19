import XCTest
import ApplicationServices
@testable import macssential

@MainActor
final class AccessibilityPermissionTests: XCTestCase {

    // MARK: - Test 1: checkPermission() returns Bool matching AXIsProcessTrusted()

    func testCheckPermissionReturnsBoolMatchingSystem() {
        let manager = AccessibilityPermissionManager()
        let expected = AXIsProcessTrusted()
        let result = manager.checkPermission()
        XCTAssertEqual(result, expected, "checkPermission() should return same value as AXIsProcessTrusted()")
    }

    // MARK: - Test 2: isGranted initial value matches AXIsProcessTrusted()

    func testIsGrantedInitialValueMatchesSystem() {
        let manager = AccessibilityPermissionManager()
        let expected = AXIsProcessTrusted()
        XCTAssertEqual(manager.isGranted, expected, "isGranted should initialize to AXIsProcessTrusted() value")
    }

    // MARK: - Test 3: startPolling sets up timer, stopPolling invalidates it

    func testStartAndStopPolling() {
        let manager = AccessibilityPermissionManager()

        // Before polling, no timer should exist
        XCTAssertFalse(manager.isPolling, "Should not be polling before startPolling()")

        // Start polling
        manager.startPolling(interval: 1.0)
        XCTAssertTrue(manager.isPolling, "Should be polling after startPolling()")

        // Stop polling
        manager.stopPolling()
        XCTAssertFalse(manager.isPolling, "Should not be polling after stopPolling()")
    }

    // MARK: - Transition callbacks from checkPermission() (screenshot-intercept-drops)
    // Regression: checkPermission() used to overwrite isGranted WITHOUT firing the
    // transition callbacks. A revoked→granted transition first observed by a panel-open
    // checkPermission() then never fired onPermissionRestored, so modules were never
    // reactivated — every tap module stayed enabled-but-dead with permission granted.

    func testCheckPermissionFiresRestoredCallbackOnGrantTransition() {
        let manager = AccessibilityPermissionManager()
        manager.trustCheck = { true }
        manager.isGranted = false

        var restoredCount = 0
        var revokedCount = 0
        manager.onPermissionRestored = { restoredCount += 1 }
        manager.onPermissionRevoked = { revokedCount += 1 }

        XCTAssertTrue(manager.checkPermission())
        XCTAssertEqual(restoredCount, 1,
            "revoked→granted observed by checkPermission() must fire onPermissionRestored")
        XCTAssertEqual(revokedCount, 0)

        // No transition on the second check — must not re-fire.
        XCTAssertTrue(manager.checkPermission())
        XCTAssertEqual(restoredCount, 1, "steady granted state must not re-fire the callback")
    }

    func testCheckPermissionFiresRevokedCallbackOnRevokeTransition() {
        let manager = AccessibilityPermissionManager()
        manager.trustCheck = { false }
        manager.isGranted = true

        var restoredCount = 0
        var revokedCount = 0
        manager.onPermissionRestored = { restoredCount += 1 }
        manager.onPermissionRevoked = { revokedCount += 1 }

        XCTAssertFalse(manager.checkPermission())
        XCTAssertEqual(revokedCount, 1,
            "granted→revoked observed by checkPermission() must fire onPermissionRevoked")
        XCTAssertEqual(restoredCount, 0)

        // No transition on the second check — must not re-fire.
        XCTAssertFalse(manager.checkPermission())
        XCTAssertEqual(revokedCount, 1, "steady revoked state must not re-fire the callback")
    }

    // MARK: - Test 4: startPolling replaces existing timer

    func testStartPollingReplacesExistingTimer() {
        let manager = AccessibilityPermissionManager()

        manager.startPolling(interval: 2.0)
        XCTAssertTrue(manager.isPolling)

        // Starting again should not crash and should still be polling
        manager.startPolling(interval: 1.0)
        XCTAssertTrue(manager.isPolling)

        manager.stopPolling()
        XCTAssertFalse(manager.isPolling)
    }
}
