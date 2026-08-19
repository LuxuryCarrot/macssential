import XCTest
@testable import macssential

// MARK: - Test Helper: Mock Module

@Observable
final class MockFeatureModule: FeatureModule {
    let id: String
    let name: String
    let icon: String
    let isAvailable: Bool

    var isEnabled: Bool = false

    var activateCallCount = 0
    var deactivateCallCount = 0

    init(id: String, name: String = "Mock", icon: String = "star", isAvailable: Bool = true) {
        self.id = id
        self.name = name
        self.icon = icon
        self.isAvailable = isAvailable
    }

    func activate() {
        activateCallCount += 1
    }

    func deactivate() {
        deactivateCallCount += 1
    }
}

// MARK: - Protocol & Registry Tests

final class FeatureModuleProtocolTests: XCTestCase {

    @MainActor func testMockModuleConformsToProtocol() {
        let module: any FeatureModule = MockFeatureModule(id: "test-1")
        XCTAssertEqual(module.id, "test-1")
        XCTAssertEqual(module.name, "Mock")
        XCTAssertEqual(module.icon, "star")
        XCTAssertTrue(module.isAvailable)
        XCTAssertFalse(module.isEnabled)
        XCTAssertNil(module.settingsView)
    }

    func testRegistryModulesReturnInRegistrationOrder() {
        let moduleA = MockFeatureModule(id: "a")
        let moduleB = MockFeatureModule(id: "b")
        let moduleC = MockFeatureModule(id: "c")
        let registry = ModuleRegistry(modules: [moduleA, moduleB, moduleC])

        XCTAssertEqual(registry.modules.count, 3)
        XCTAssertEqual(registry.modules[0].id, "a")
        XCTAssertEqual(registry.modules[1].id, "b")
        XCTAssertEqual(registry.modules[2].id, "c")
    }

    func testActivateEnabledModulesOnlyActivatesEnabledAndAvailable() {
        let enabledAvailable = MockFeatureModule(id: "ea", isAvailable: true)
        enabledAvailable.isEnabled = true

        let enabledUnavailable = MockFeatureModule(id: "eu", isAvailable: false)
        enabledUnavailable.isEnabled = true

        let disabledAvailable = MockFeatureModule(id: "da", isAvailable: true)
        disabledAvailable.isEnabled = false

        let registry = ModuleRegistry(modules: [enabledAvailable, enabledUnavailable, disabledAvailable])
        registry.activateEnabledModules()

        XCTAssertEqual(enabledAvailable.activateCallCount, 1, "Should activate enabled+available module")
        XCTAssertEqual(enabledUnavailable.activateCallCount, 0, "Should NOT activate enabled+unavailable module")
        XCTAssertEqual(disabledAvailable.activateCallCount, 0, "Should NOT activate disabled module")
    }
}

// MARK: - Concrete Module Tests

final class FeatureModuleTests: XCTestCase {

    // UserDefaults keys for cleanup
    private let allKeys = [
        "com.macssential.module.dock-anchor.enabled",
        "com.macssential.module.key-repeat.enabled",
        "com.macssential.module.dock-autohide.enabled",
        "com.macssential.module.dock-recent-apps.enabled",
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

    // MARK: - Test 1: DockAnchorModule properties

    func testDockAnchorModuleProperties() {
        let module = DockAnchorModule()
        XCTAssertEqual(module.id, "dock-anchor")
        XCTAssertEqual(module.name, String(localized: "module.dock_anchor.name"))
        XCTAssertEqual(module.icon, "dock.rectangle")
        XCTAssertTrue(module.isAvailable)
    }


    // MARK: - Test 3: UserDefaults persistence (write)

    func testUserDefaultsPersistence() {
        let module = DockAnchorModule()
        module.isEnabled = true

        let storedValue = UserDefaults.standard.bool(forKey: "com.macssential.module.dock-anchor.enabled")
        XCTAssertTrue(storedValue, "Setting isEnabled=true should persist to UserDefaults")
    }

    // MARK: - Test 4: UserDefaults persistence (round-trip)

    func testUserDefaultsRoundTrip() {
        // Set value via one instance
        let module1 = DockAnchorModule()
        module1.isEnabled = true

        // Read value via new instance
        let module2 = DockAnchorModule()
        XCTAssertTrue(module2.isEnabled, "New module instance should read isEnabled from UserDefaults")
    }


    // MARK: - Test 5: Module independence

    func testModuleIndependence() {
        // Use the UserDefaults-backed KFN module: HiddenFiles mirrors live system
        // state (defaults read AppleShowAllFiles), so it is not a stable fixture.
        UserDefaults.standard.removeObject(forKey: "com.macssential.module.kfn.enabled")
        let dockAnchor = DockAnchorModule()
        let kfn = KoreanFilenameNormalizerModule()

        // Toggle only dock anchor
        dockAnchor.isEnabled = true

        // KFN should remain off
        XCTAssertFalse(kfn.isEnabled, "Toggling DockAnchor should not affect other modules")
    }

    // MARK: - Test 6: Default state (first launch)

    func testDefaultState() {
        // With no UserDefaults keys set (cleared in setUp), all modules default to off
        UserDefaults.standard.removeObject(forKey: "com.macssential.module.kfn.enabled")
        let dockAnchor = DockAnchorModule()
        let kfn = KoreanFilenameNormalizerModule()

        XCTAssertFalse(dockAnchor.isEnabled, "DockAnchor should default to off")
        XCTAssertFalse(kfn.isEnabled, "KFN should default to off")
    }

    // MARK: - Registry default modules order

    func testDefaultRegistryOrder() {
        let registry = ModuleRegistry()
#if DEBUG
        // FinderSort is registered only in Debug builds (QUICK-KBR-02), after HiddenFiles.
        var expectedIDs = ["dock-anchor", "dock-autohide", "dock-recent-apps", "hidden-files",
                           "finder-sort"]
#else
        var expectedIDs = ["dock-anchor", "dock-autohide", "dock-recent-apps", "hidden-files"]
#endif
        expectedIDs += ["key-repeat", "scroll-direction", "screenshot-auto-copy",
                        "korean-filename-normalizer"]
        XCTAssertEqual(registry.modules.map(\.id), expectedIDs)
    }
}
