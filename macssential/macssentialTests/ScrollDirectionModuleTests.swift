import XCTest
@testable import macssential

final class ScrollDirectionModuleTests: XCTestCase {

    private let allKeys = [
        "com.macssential.module.scroll-direction.enabled",
    ]

    override func setUp() {
        super.setUp()
        for key in allKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        for key in allKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

    // MARK: - Protocol Conformance

    func testProtocolConformance() {
        let module = ScrollDirectionModule()
        XCTAssertEqual(module.id, "scroll-direction")
        XCTAssertFalse(module.name.isEmpty)
        XCTAssertEqual(module.icon, "computermouse")
    }

    // MARK: - Availability

    func testIsAvailable() {
        let module = ScrollDirectionModule()
        XCTAssertTrue(module.isAvailable)
    }

    // MARK: - Enabled Persistence

    func testEnabledPersistence() {
        let module1 = ScrollDirectionModule()
        module1.isEnabled = true

        let module2 = ScrollDirectionModule()
        XCTAssertTrue(module2.isEnabled, "isEnabled should persist across instances")
    }

    // MARK: - Settings View

    @MainActor func testSettingsViewIsNil() {
        let module = ScrollDirectionModule()

        // When disabled, settingsView should be nil
        module.isEnabled = false
        XCTAssertNil(module.settingsView, "settingsView should be nil when disabled")

        // When enabled, settingsView should still be nil (simple toggle only, no settings UI)
        module.isEnabled = true
        XCTAssertNil(module.settingsView, "settingsView should be nil when enabled (simple toggle module)")
    }

    // MARK: - Default State

    func testDefaultDisabled() {
        let module = ScrollDirectionModule()
        XCTAssertFalse(module.isEnabled, "Fresh module should be disabled by default")
    }

    // Note: panel visibility is now governed by PanelConfiguration (see PanelConfigurationTests),
    // not a per-module isPanelVisible flag. Scroll Direction is default-hidden from the panel there.
}
