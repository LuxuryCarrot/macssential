import XCTest
@testable import macssential

// MARK: - Mock System Controller

/// Records `setSystemRecentsShown` calls and serves a settable system show-recents
/// value, so tests never touch the real `com.apple.dock` domain or restart the Dock.
final class MockDockRecentAppsSystem: DockRecentAppsSystemControlling {
    var systemRecentsShown: Bool
    private(set) var setCalls: [Bool] = []

    init(systemRecentsShown: Bool = true) {
        self.systemRecentsShown = systemRecentsShown
    }

    func isSystemRecentsShown() -> Bool {
        systemRecentsShown
    }

    func setSystemRecentsShown(_ shown: Bool) {
        setCalls.append(shown)
        systemRecentsShown = shown
    }
}

final class DockRecentAppsModuleTests: XCTestCase {

    private let enabledKey = "com.macssential.module.dock-recent-apps.enabled"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: enabledKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: enabledKey)
        super.tearDown()
    }

    // MARK: - Properties

    func testDockRecentAppsModuleProperties() {
        let module = DockRecentAppsModule(system: MockDockRecentAppsSystem())
        XCTAssertEqual(module.id, "dock-recent-apps")
        XCTAssertEqual(module.name, String(localized: "module.dock_recent_apps.name"))
        XCTAssertEqual(module.icon, "clock.arrow.circlepath")
        XCTAssertTrue(module.isAvailable)
    }

    // MARK: - Init Syncs From System (system is source of truth)

    func testInitSyncsFromSystemWhenRecentsHiddenAndFlagFalse() {
        UserDefaults.standard.set(false, forKey: enabledKey)
        let mock = MockDockRecentAppsSystem(systemRecentsShown: false)

        let module = DockRecentAppsModule(system: mock)

        XCTAssertTrue(module.isEnabled, "Init must derive isEnabled from the real system state (recents hidden means enabled), not the stale app flag")
        XCTAssertTrue(mock.setCalls.isEmpty, "Init must never fire setSystemRecentsShown")
    }

    func testInitSyncsFromSystemWhenRecentsShownAndFlagTrue() {
        UserDefaults.standard.set(true, forKey: enabledKey)
        let mock = MockDockRecentAppsSystem(systemRecentsShown: true)

        let module = DockRecentAppsModule(system: mock)

        XCTAssertFalse(module.isEnabled, "Init must derive isEnabled from the real system state (recents shown means disabled), not the stale app flag")
        XCTAssertTrue(mock.setCalls.isEmpty, "Init must never fire setSystemRecentsShown")
    }

    // MARK: - syncFromSystem

    func testSyncFromSystemUpdatesFlagWithoutSideEffects() {
        let mock = MockDockRecentAppsSystem(systemRecentsShown: true)
        let module = DockRecentAppsModule(system: mock)
        XCTAssertFalse(module.isEnabled)

        // External change (e.g. System Settings hides recents)
        mock.systemRecentsShown = false
        module.syncFromSystem()

        XCTAssertTrue(module.isEnabled, "syncFromSystem must adopt the real system state")
        XCTAssertTrue(mock.setCalls.isEmpty, "syncFromSystem must never fire setSystemRecentsShown")
    }

    // MARK: - Idempotent activate/deactivate

    func testActivateIsIdempotentWhenRecentsAlreadyHidden() {
        // Stale-flag scenario: flag false, system already hidden. Init adopts
        // enabled=true; flipping the toggle OFF→ON again must not restart the Dock.
        let mock = MockDockRecentAppsSystem(systemRecentsShown: false)
        let module = DockRecentAppsModule(system: mock)
        XCTAssertTrue(module.isEnabled)

        module.isEnabled = true

        XCTAssertTrue(mock.setCalls.isEmpty, "Enabling when recents are already hidden must not restart the Dock")
    }

    func testDeactivateIsIdempotentWhenRecentsAlreadyShown() {
        let mock = MockDockRecentAppsSystem(systemRecentsShown: true)
        let module = DockRecentAppsModule(system: mock)
        XCTAssertFalse(module.isEnabled)

        module.isEnabled = false

        XCTAssertTrue(mock.setCalls.isEmpty, "Disabling when recents are already shown must not restart the Dock")
    }

    // MARK: - Normal path

    func testActivateWritesWhenRecentsShown() {
        let mock = MockDockRecentAppsSystem(systemRecentsShown: true)
        let module = DockRecentAppsModule(system: mock)

        module.isEnabled = true

        XCTAssertEqual(mock.setCalls, [false], "Enabling from recents-shown must fire exactly one setSystemRecentsShown(false)")
    }

    func testDeactivateWritesWhenRecentsHidden() {
        let mock = MockDockRecentAppsSystem(systemRecentsShown: false)
        let module = DockRecentAppsModule(system: mock)
        XCTAssertTrue(module.isEnabled)

        module.isEnabled = false

        XCTAssertEqual(mock.setCalls, [true], "Explicit toggle-OFF must fire exactly one setSystemRecentsShown(true)")
    }

    // MARK: - Persistence mirror

    func testEnabledPersistence() {
        let mock = MockDockRecentAppsSystem(systemRecentsShown: true)
        let module = DockRecentAppsModule(system: mock)
        module.isEnabled = true

        let storedValue = UserDefaults.standard.bool(forKey: enabledKey)
        XCTAssertTrue(storedValue, "Setting isEnabled=true should persist to UserDefaults")
    }

    // MARK: - Registry integration (panel-open sync)

    func testRegistrySyncModulesFromSystemAdoptsDesyncedValue() {
        let mock = MockDockRecentAppsSystem(systemRecentsShown: true)
        let module = DockRecentAppsModule(system: mock)
        XCTAssertFalse(module.isEnabled)

        // Desync: recents hidden externally, module flag still false.
        mock.systemRecentsShown = false

        let registry = ModuleRegistry(modules: [module])
        registry.syncModulesFromSystem()

        XCTAssertTrue(module.isEnabled, "syncModulesFromSystem must adopt the real system state via SystemStateSyncing")
        XCTAssertTrue(mock.setCalls.isEmpty, "syncModulesFromSystem must fire no system writes")
    }
}
