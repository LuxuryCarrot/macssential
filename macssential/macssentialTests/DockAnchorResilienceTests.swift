import XCTest
@testable import macssential

final class DockAnchorResilienceTests: XCTestCase {

    // MARK: - Test 6: preferredDisplay is set when user selects a display

    func testPreferredDisplaySetOnSelection() {
        let module = DockAnchorModule()
        let mainID = CGMainDisplayID()

        // Simulate user selecting a display via the computed property
        module.selectedDisplayID = mainID

        XCTAssertNotNil(module.preferredDisplay,
                         "preferredDisplay should be set after selectedDisplayID assignment")
        XCTAssertEqual(module.preferredDisplay?.vendorNumber,
                        CGDisplayVendorNumber(mainID))
    }

    // MARK: - Test 7: Single monitor pauses interceptor and sets statusMessage

    func testSingleMonitorPausesInterceptor() {
        let module = DockAnchorModule()
        // handleScreenChange() checks NSScreen.screens -- we can't mock that easily
        // But we can call handleScreenChange() and verify behavior based on actual screen count
        // On a single-monitor test machine: interceptor should pause
        // On a multi-monitor test machine: interceptor should not pause
        // We test the statusMessage and isPaused properties after calling handleScreenChange

        // Since we can't control NSScreen.screens, test the module's properties
        // after handleScreenChange for the current environment
        module.handleScreenChange()

        if NSScreen.screens.count <= 1 {
            XCTAssertEqual(module.statusMessage, "Paused \u{2014} single monitor detected",
                            "Should set paused status message on single monitor")
        } else {
            // Multi-monitor: should not set paused message
            XCTAssertNotEqual(module.statusMessage, "Paused \u{2014} single monitor detected",
                               "Should not show pause message on multi-monitor")
        }
    }

    // MARK: - Test 8: Preferred display fingerprint resolves on reconnect

    func testPreferredDisplayResolvesOnReconnect() {
        let module = DockAnchorModule()
        let mainID = CGMainDisplayID()

        // Set preferred to main display (which is always connected)
        module.selectedDisplayID = mainID

        // Simulate screen change -- preferred should still resolve
        module.handleScreenChange()

        if NSScreen.screens.count > 1 {
            // On multi-monitor: preferred found, activeDisplayID should match
            XCTAssertEqual(module.activeDisplayID, mainID,
                            "Should restore to preferred display when it's still connected")
            XCTAssertNil(module.statusMessage,
                          "Should have nil statusMessage on silent restore (D-05)")
        }
    }

    // MARK: - Test 9: Fallback selects CGMainDisplayID

    func testFallbackSelectsMainDisplay() {
        let module = DockAnchorModule()

        // Set preferred to a non-existent display fingerprint
        module.preferredDisplay = DisplayIdentifier(
            vendorNumber: 99999, modelNumber: 99999, serialNumber: 99999, localizedName: "Phantom"
        )

        module.handleScreenChange()

        if NSScreen.screens.count > 1 {
            // Preferred not found, should fall back to CGMainDisplayID
            XCTAssertEqual(module.activeDisplayID, CGMainDisplayID(),
                            "Should fallback to CGMainDisplayID when preferred not found")
        }
    }

    // MARK: - Test 10: Status message on fallback (D-02)

    func testStatusMessageOnFallback() {
        let module = DockAnchorModule()

        // Set preferred to non-existent display
        module.preferredDisplay = DisplayIdentifier(
            vendorNumber: 99999, modelNumber: 99999, serialNumber: 99999, localizedName: "Phantom"
        )

        module.handleScreenChange()

        if NSScreen.screens.count > 1 {
            XCTAssertNotNil(module.statusMessage,
                             "Should set status message when preferred monitor not found")
            XCTAssertTrue(module.statusMessage?.contains("Monitor disconnected") ?? false,
                           "Status message should mention monitor disconnected")
        }
    }

    // MARK: - Test 11: Silent restore (D-05)

    func testSilentRestoreNoStatusMessage() {
        let module = DockAnchorModule()
        let mainID = CGMainDisplayID()

        // Set preferred to main display (always connected)
        module.selectedDisplayID = mainID
        module.handleScreenChange()

        if NSScreen.screens.count > 1 {
            XCTAssertNil(module.statusMessage,
                          "statusMessage should be nil on silent restore (D-05)")
        }
    }

    // MARK: - Test 12: selectedModifierKey defaults to .option and persists

    func testSelectedModifierKeyDefaultsAndPersists() {
        // Clean up any existing value
        UserDefaults.standard.removeObject(forKey: ModifierKeyOption.defaultsKey)

        let module = DockAnchorModule()
        XCTAssertEqual(module.selectedModifierKey, .option,
                        "Default modifier key should be .option")

        // Change to .control
        module.selectedModifierKey = .control

        // Verify persistence
        let stored = UserDefaults.standard.string(forKey: ModifierKeyOption.defaultsKey)
        XCTAssertEqual(stored, "control",
                        "selectedModifierKey should persist to UserDefaults")

        // Clean up
        UserDefaults.standard.removeObject(forKey: ModifierKeyOption.defaultsKey)
    }
}
