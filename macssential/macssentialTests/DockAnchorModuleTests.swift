import XCTest
@testable import macssential

final class DockAnchorModuleTests: XCTestCase {
    private let monitorKey = "com.macssential.module.dock-anchor.monitor"
    private let enabledKey = "com.macssential.module.dock-anchor.enabled"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: monitorKey)
        UserDefaults.standard.removeObject(forKey: enabledKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: monitorKey)
        UserDefaults.standard.removeObject(forKey: enabledKey)
        super.tearDown()
    }

    func testIsAvailableIsTrue() {
        let module = DockAnchorModule()
        XCTAssertTrue(module.isAvailable)
    }

    func testDefaultDisplayIDIsMainDisplay() {
        let module = DockAnchorModule()
        XCTAssertEqual(module.selectedDisplayID, CGMainDisplayID())
    }

    func testSelectedDisplayIDPersists() {
        let module = DockAnchorModule()
        let testID: CGDirectDisplayID = 12345
        module.selectedDisplayID = testID
        let stored = UserDefaults.standard.integer(forKey: monitorKey)
        XCTAssertEqual(CGDirectDisplayID(stored), testID)
    }

    @MainActor func testSettingsViewNilWhenDisabled() {
        let module = DockAnchorModule()
        module.isEnabled = false
        XCTAssertNil(module.settingsView)
    }

    @MainActor func testSettingsViewNotNilWhenEnabled() {
        let module = DockAnchorModule()
        module.isEnabled = true
        XCTAssertNotNil(module.settingsView)
    }
}
