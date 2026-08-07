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
