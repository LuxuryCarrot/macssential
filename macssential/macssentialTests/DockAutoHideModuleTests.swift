import XCTest
@testable import macssential

// MARK: - Mock System Controller

/// Records `setSystemAutoHide` calls and serves a settable system autohide value,
/// so tests never touch the real `com.apple.dock` domain or restart the Dock.
final class MockDockAutoHideSystem: DockAutoHideSystemControlling {
    var systemAutoHideOn: Bool
    private(set) var setCalls: [Bool] = []

    init(systemAutoHideOn: Bool = false) {
        self.systemAutoHideOn = systemAutoHideOn
    }

    func isSystemAutoHideOn() -> Bool {
        systemAutoHideOn
    }

    func setSystemAutoHide(_ on: Bool) {
        setCalls.append(on)
        systemAutoHideOn = on
    }
}

final class DockAutoHideModuleTests: XCTestCase {

    private let enabledKey = "com.macssential.module.dock-autohide.enabled"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: enabledKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: enabledKey)
        super.tearDown()
    }

    // MARK: - Properties

    func testDockAutoHideModuleProperties() {
        let module = DockAutoHideModule(system: MockDockAutoHideSystem())
        XCTAssertEqual(module.id, "dock-autohide")
        XCTAssertEqual(module.name, String(localized: "module.dock_autohide.name"))
        XCTAssertEqual(module.icon, "dock.arrow.down.rectangle")
        XCTAssertTrue(module.isAvailable)
    }

    // MARK: - Default State

    func testDefaultState() {
        let module = DockAutoHideModule(system: MockDockAutoHideSystem(systemAutoHideOn: false))
        XCTAssertFalse(module.isEnabled, "DockAutoHide should default to off when system autohide is off")
    }

    // MARK: - Init Syncs From System (system is source of truth)

    func testInitSyncsFromSystemWhenSystemOnAndFlagFalse() {
        UserDefaults.standard.set(false, forKey: enabledKey)
        let mock = MockDockAutoHideSystem(systemAutoHideOn: true)

        let module = DockAutoHideModule(system: mock)

        XCTAssertTrue(module.isEnabled, "Init must derive isEnabled from the real system state, not the stale app flag")
        XCTAssertTrue(mock.setCalls.isEmpty, "Init must never fire setSystemAutoHide")
    }

    func testInitSyncsFromSystemWhenSystemOffAndFlagTrue() {
        UserDefaults.standard.set(true, forKey: enabledKey)
        let mock = MockDockAutoHideSystem(systemAutoHideOn: false)

        let module = DockAutoHideModule(system: mock)

        XCTAssertFalse(module.isEnabled, "Init must derive isEnabled from the real system state, not the stale app flag")
        XCTAssertTrue(mock.setCalls.isEmpty, "Init must never fire setSystemAutoHide")
    }

    // MARK: - syncFromSystem

    func testSyncFromSystemUpdatesFlagWithoutSideEffects() {
        let mock = MockDockAutoHideSystem(systemAutoHideOn: false)
        let module = DockAutoHideModule(system: mock)
        XCTAssertFalse(module.isEnabled)

        // External change (e.g. Cmd+Opt+D outside the app)
        mock.systemAutoHideOn = true
        module.syncFromSystem()

        XCTAssertTrue(module.isEnabled, "syncFromSystem must adopt the real system state")
        XCTAssertTrue(mock.setCalls.isEmpty, "syncFromSystem must never fire setSystemAutoHide")
    }

    // MARK: - Idempotent activate/deactivate

    func testDeactivateIsIdempotentWhenSystemAlreadyOff() {
        let mock = MockDockAutoHideSystem(systemAutoHideOn: false)
        let module = DockAutoHideModule(system: mock)

        module.isEnabled = false

        XCTAssertTrue(mock.setCalls.isEmpty, "Deactivating an already-visible Dock must not restart the Dock")
    }

    func testActivateWritesWhenSystemOff() {
        let mock = MockDockAutoHideSystem(systemAutoHideOn: false)
        let module = DockAutoHideModule(system: mock)

        module.isEnabled = true

        XCTAssertEqual(mock.setCalls, [true], "Enabling from system-off must fire exactly one setSystemAutoHide(true)")
    }

    // MARK: - Persistence

    func testEnabledPersistence() {
        let mock = MockDockAutoHideSystem(systemAutoHideOn: false)
        let module = DockAutoHideModule(system: mock)
        module.isEnabled = true

        let storedValue = UserDefaults.standard.bool(forKey: enabledKey)
        XCTAssertTrue(storedValue, "Setting isEnabled=true should persist to UserDefaults")
    }

    // MARK: - Round-trip

    func testEnabledRoundTrip() {
        let mock = MockDockAutoHideSystem(systemAutoHideOn: false)
        let module1 = DockAutoHideModule(system: mock)
        module1.isEnabled = true

        // A new instance reads the (mock) system state — which the first instance set to on.
        let module2 = DockAutoHideModule(system: mock)
        XCTAssertTrue(module2.isEnabled, "New instance should derive isEnabled from the system state")
    }
}

// MARK: - ModuleRegistry Conflict Resolution

/// Minimal stand-in for DockAnchorModule so registry tests need no Accessibility permission.
private final class StubAnchorModule: FeatureModule {
    let id = "dock-anchor"
    let name = "Anchor Stub"
    let icon = "circle"
    let isAvailable = true
    var isEnabled = false
    private(set) var releaseResourcesCalled = false
    func activate() {}
    func deactivate() {}
    func releaseResources() { releaseResourcesCalled = true }
}

final class ModuleRegistryConflictTests: XCTestCase {

    private let enabledKey = "com.macssential.module.dock-autohide.enabled"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: enabledKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: enabledKey)
        super.tearDown()
    }

    /// Exact reproduction of the reported bug: system autohide is ON but the
    /// module flag desynced to false — enabling dock-anchor must still raise the Dock.
    func testDisableConflictingFixesDesyncedAutohide() {
        let mock = MockDockAutoHideSystem(systemAutoHideOn: false)
        let autohide = DockAutoHideModule(system: mock)
        XCTAssertFalse(autohide.isEnabled)

        // Desync: system flips ON externally, module flag still false.
        mock.systemAutoHideOn = true

        let registry = ModuleRegistry(modules: [StubAnchorModule(), autohide])
        registry.disableConflicting(with: "dock-anchor")

        XCTAssertEqual(mock.setCalls, [false], "Desynced autohide must be turned off at the system level")
        XCTAssertFalse(autohide.isEnabled)
    }

    /// No needless Dock restart when both flag and system are already off.
    func testDisableConflictingNoRestartWhenAlreadyOff() {
        let mock = MockDockAutoHideSystem(systemAutoHideOn: false)
        let autohide = DockAutoHideModule(system: mock)

        let registry = ModuleRegistry(modules: [StubAnchorModule(), autohide])
        registry.disableConflicting(with: "dock-anchor")

        XCTAssertTrue(mock.setCalls.isEmpty, "Dock must not be restarted when system autohide is already off")
        XCTAssertFalse(autohide.isEnabled)
    }

    /// Normal path: enabled autohide module gets disabled and the system write fires.
    func testDisableConflictingNormalPath() {
        let mock = MockDockAutoHideSystem(systemAutoHideOn: true)
        let autohide = DockAutoHideModule(system: mock)
        XCTAssertTrue(autohide.isEnabled)

        let registry = ModuleRegistry(modules: [StubAnchorModule(), autohide])
        registry.disableConflicting(with: "dock-anchor")

        XCTAssertFalse(autohide.isEnabled)
        XCTAssertEqual(mock.setCalls, [false])
    }

    /// Panel-open refresh: syncs SystemStateSyncing modules with zero system writes.
    func testSyncModulesFromSystem() {
        let mock = MockDockAutoHideSystem(systemAutoHideOn: false)
        let autohide = DockAutoHideModule(system: mock)
        XCTAssertFalse(autohide.isEnabled)

        mock.systemAutoHideOn = true

        let registry = ModuleRegistry(modules: [StubAnchorModule(), autohide])
        registry.syncModulesFromSystem()

        XCTAssertTrue(autohide.isEnabled, "syncModulesFromSystem must adopt the real system state")
        XCTAssertTrue(mock.setCalls.isEmpty, "syncModulesFromSystem must fire no system writes")
    }
}

// MARK: - ModuleRegistry Quit-Time Resource Release

/// Quit and permission-revocation must release ONLY live runtime resources
/// (CGEventTaps, FSEvents streams) — never revert persistent system preferences.
final class ModuleRegistryReleaseResourcesTests: XCTestCase {

    private let autoHideKey = "com.macssential.module.dock-autohide.enabled"
    private let recentAppsKey = "com.macssential.module.dock-recent-apps.enabled"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: autoHideKey)
        UserDefaults.standard.removeObject(forKey: recentAppsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: autoHideKey)
        UserDefaults.standard.removeObject(forKey: recentAppsKey)
        super.tearDown()
    }

    /// Quit must NOT revert preference modules: enabled DockAutoHide and
    /// DockRecentApps stay enabled with zero system writes.
    func testReleaseAllRuntimeResourcesDoesNotRevertPreferenceModules() {
        let autoHideMock = MockDockAutoHideSystem(systemAutoHideOn: true)
        let autohide = DockAutoHideModule(system: autoHideMock)
        XCTAssertTrue(autohide.isEnabled)

        let recentsMock = MockDockRecentAppsSystem(systemRecentsShown: false)
        let recents = DockRecentAppsModule(system: recentsMock)
        XCTAssertTrue(recents.isEnabled)

        let registry = ModuleRegistry(modules: [StubAnchorModule(), autohide, recents])
        registry.releaseAllRuntimeResources()

        XCTAssertTrue(autoHideMock.setCalls.isEmpty, "Quit must not write to com.apple.dock autohide")
        XCTAssertTrue(recentsMock.setCalls.isEmpty, "Quit must not write to com.apple.dock show-recents")
        XCTAssertTrue(autohide.isEnabled, "DockAutoHide must stay enabled through quit")
        XCTAssertTrue(recents.isEnabled, "DockRecentApps must stay enabled through quit")
    }

    /// Quit must still release live runtime resources (CGEventTaps) — even for
    /// modules whose isEnabled is false, since a tap could exist from an earlier state.
    func testReleaseAllRuntimeResourcesReleasesRuntimeModulesRegardlessOfEnabled() {
        let stub = StubAnchorModule()
        XCTAssertFalse(stub.isEnabled)

        let registry = ModuleRegistry(modules: [stub])
        registry.releaseAllRuntimeResources()

        XCTAssertTrue(stub.releaseResourcesCalled, "releaseResources must fire regardless of isEnabled so no tap can leak")
    }

    /// e8f regression closure: enabled DockAutoHide survives an app restart —
    /// quit no longer writes autohide=false, so a new instance still reads enabled.
    func testDockAutoHideEnabledStateSurvivesRestart() {
        let mock = MockDockAutoHideSystem(systemAutoHideOn: true)
        let autohide = DockAutoHideModule(system: mock)
        XCTAssertTrue(autohide.isEnabled)

        let registry = ModuleRegistry(modules: [autohide])
        registry.releaseAllRuntimeResources()

        // Simulated relaunch: new module instance against the same system state.
        let relaunched = DockAutoHideModule(system: mock)
        XCTAssertTrue(relaunched.isEnabled, "DockAutoHide must not self-disable across app restarts")
    }
}
