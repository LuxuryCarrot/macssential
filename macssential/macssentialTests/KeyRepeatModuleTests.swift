import XCTest
@testable import macssential

// MARK: - Spy Applier

/// Records apply/restore calls so tests never touch the real global preferences domain.
final class SpyKeyRepeatApplier: GlobalKeyRepeatApplying {
    private(set) var applyCalls: [(initialKeyRepeat: Int, keyRepeat: Int)] = []
    private(set) var restoreCalls = 0
    private(set) var liveHIDCalls: [(initialKeyRepeatNs: Int, keyRepeatNs: Int)] = []
    private(set) var disablePressAndHoldCalls = 0
    private(set) var restorePressAndHoldCalls = 0

    func apply(initialKeyRepeat: Int, keyRepeat: Int) {
        applyCalls.append((initialKeyRepeat: initialKeyRepeat, keyRepeat: keyRepeat))
    }

    func restoreSystemDefaults() {
        restoreCalls += 1
    }

    func applyLiveHID(initialKeyRepeatNs: Int, keyRepeatNs: Int) {
        liveHIDCalls.append((initialKeyRepeatNs: initialKeyRepeatNs, keyRepeatNs: keyRepeatNs))
    }

    func disablePressAndHold() {
        disablePressAndHoldCalls += 1
    }

    func restorePressAndHold() {
        restorePressAndHoldCalls += 1
    }
}

// MARK: - KeyRepeatModuleTests

final class KeyRepeatModuleTests: XCTestCase {

    private static let suiteName = "com.macssential.tests.key-repeat"

    private var defaults: UserDefaults!
    private var spy: SpyKeyRepeatApplier!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: Self.suiteName)
        defaults.removePersistentDomain(forName: Self.suiteName)
        spy = SpyKeyRepeatApplier()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: Self.suiteName)
        defaults = nil
        spy = nil
        super.tearDown()
    }

    private func makeModule() -> KeyRepeatModule {
        KeyRepeatModule(applier: spy, defaults: defaults)
    }

    // MARK: - Test 1: Fresh defaults

    func testFreshModuleDefaults() {
        let module = makeModule()
        XCTAssertEqual(module.initialKeyRepeat, 14,
            "Fresh module should default to InitialKeyRepeat 14 (range maximum — old seed 15 is out of the truncated range)")
        XCTAssertEqual(module.keyRepeat, 2,
            "Fresh module should default to KeyRepeat 2 (System Settings fastest)")
        XCTAssertFalse(module.isEnabled, "Fresh module should be disabled by default")
    }

    // MARK: - Test 2: activate() applies stored values

    func testActivateAppliesStoredValues() {
        let module = makeModule()
        module.activate()
        XCTAssertEqual(spy.applyCalls.count, 1, "activate() must call applier.apply exactly once")
        XCTAssertEqual(spy.applyCalls.first?.initialKeyRepeat, 14)
        XCTAssertEqual(spy.applyCalls.first?.keyRepeat, 2)
        XCTAssertEqual(spy.liveHIDCalls.count, 1,
            "activate() must set the live HID parameters exactly once for immediate effect")
        XCTAssertEqual(spy.liveHIDCalls.first?.initialKeyRepeatNs, 233_333_333,
            "14 ticks × 1/60 s ≈ 233.33 ms = 233333333 ns")
        XCTAssertEqual(spy.liveHIDCalls.first?.keyRepeatNs, 33_333_333,
            "2 ticks × 1/60 s ≈ 33.33 ms = 33333333 ns")
        XCTAssertEqual(spy.disablePressAndHoldCalls, 1,
            "activate() must disable press-and-hold exactly once so held keys repeat instead of showing the accent picker")
    }

    // MARK: - Test 3: deactivate() restores system defaults

    func testDeactivateRestoresSystemDefaults() {
        let module = makeModule()
        module.deactivate()
        XCTAssertEqual(spy.restoreCalls, 1,
            "deactivate() must delete the global keys via applier.restoreSystemDefaults()")
        XCTAssertTrue(spy.applyCalls.isEmpty, "deactivate() must not apply values")
        XCTAssertEqual(spy.liveHIDCalls.count, 1,
            "deactivate() must revert live HID to macOS defaults for immediate effect")
        XCTAssertEqual(spy.liveHIDCalls.first?.initialKeyRepeatNs, 416_666_667,
            "macOS default: 25 ticks × 1/60 s = 416666667 ns")
        XCTAssertEqual(spy.liveHIDCalls.first?.keyRepeatNs, 100_000_000,
            "macOS default: 6 ticks × 1/60 s = 100000000 ns")
        XCTAssertEqual(spy.restorePressAndHoldCalls, 1,
            "deactivate() must delete ApplePressAndHoldEnabled exactly once so the accent picker returns")
        XCTAssertEqual(spy.disablePressAndHoldCalls, 0,
            "deactivate() must NOT re-disable press-and-hold")
    }

    // MARK: - Test 4: Setting values — persist always, apply only while enabled

    func testSettingValuesWhileEnabledPersistsAndReapplies() {
        let module = makeModule()
        module.isEnabled = true
        let callsAfterEnable = spy.applyCalls.count
        let pressAndHoldCallsAfterEnable = spy.disablePressAndHoldCalls

        module.initialKeyRepeat = 10
        XCTAssertEqual(spy.disablePressAndHoldCalls, pressAndHoldCallsAfterEnable + 1,
            "Each slider change while enabled must re-disable press-and-hold")
        XCTAssertEqual(defaults.integer(forKey: "com.macssential.module.key-repeat.initialKeyRepeat"), 10,
            "initialKeyRepeat must persist to injected defaults")
        XCTAssertEqual(spy.applyCalls.count, callsAfterEnable + 1,
            "Changing a value while enabled must re-apply")
        XCTAssertEqual(spy.applyCalls.last?.initialKeyRepeat, 10)
        XCTAssertEqual(spy.applyCalls.last?.keyRepeat, 2)
        XCTAssertEqual(spy.liveHIDCalls.last?.initialKeyRepeatNs, 166_666_667,
            "10 ticks × 1/60 s ≈ 166.67 ms = 166666667 ns must reach live HID")
        XCTAssertEqual(spy.liveHIDCalls.last?.keyRepeatNs, 33_333_333)

        module.keyRepeat = 4
        XCTAssertEqual(defaults.integer(forKey: "com.macssential.module.key-repeat.keyRepeat"), 4,
            "keyRepeat must persist to injected defaults")
        XCTAssertEqual(spy.applyCalls.last?.initialKeyRepeat, 10)
        XCTAssertEqual(spy.applyCalls.last?.keyRepeat, 4)
        XCTAssertEqual(spy.disablePressAndHoldCalls, pressAndHoldCallsAfterEnable + 2,
            "Each slider change while enabled must re-disable press-and-hold")
    }

    func testSettingValuesWhileDisabledPersistsWithoutApplying() {
        let module = makeModule()
        module.initialKeyRepeat = 8
        module.keyRepeat = 3
        XCTAssertEqual(defaults.integer(forKey: "com.macssential.module.key-repeat.initialKeyRepeat"), 8)
        XCTAssertEqual(defaults.integer(forKey: "com.macssential.module.key-repeat.keyRepeat"), 3)
        XCTAssertTrue(spy.applyCalls.isEmpty,
            "Changing values while disabled must NOT touch the global domain")
        XCTAssertTrue(spy.liveHIDCalls.isEmpty,
            "Changing values while disabled must NOT touch the live HID parameters")
        XCTAssertEqual(spy.disablePressAndHoldCalls, 0,
            "Changing values while disabled must NOT touch press-and-hold")
        XCTAssertEqual(spy.restorePressAndHoldCalls, 0,
            "Changing values while disabled must NOT touch press-and-hold")
    }

    func testValuesPersistAcrossInstances() {
        let module1 = makeModule()
        module1.initialKeyRepeat = 7
        module1.keyRepeat = 1

        let module2 = makeModule()
        XCTAssertEqual(module2.initialKeyRepeat, 7, "Values must be read back on next init")
        XCTAssertEqual(module2.keyRepeat, 1, "Values must be read back on next init")
    }

    // MARK: - Test 5: Clamping

    func testValuesAreClampedToAllowedRanges() {
        let module = makeModule()

        module.initialKeyRepeat = 100
        XCTAssertEqual(module.initialKeyRepeat, 14, "initialKeyRepeat must clamp to max 14")
        module.initialKeyRepeat = 0
        XCTAssertEqual(module.initialKeyRepeat, 5, "initialKeyRepeat must clamp to min 5")

        module.keyRepeat = 100
        XCTAssertEqual(module.keyRepeat, 5, "keyRepeat must clamp to max 5")
        module.keyRepeat = 0
        XCTAssertEqual(module.keyRepeat, 1, "keyRepeat must clamp to min 1")
    }

    func testOutOfRangePersistedValuesClampOnLoad() {
        // Old-valid values (25/6 — the pre-truncation macOS defaults) persisted by a
        // previous app version must clamp into the new ranges on next launch.
        defaults.set(25, forKey: "com.macssential.module.key-repeat.initialKeyRepeat")
        defaults.set(6, forKey: "com.macssential.module.key-repeat.keyRepeat")

        let module = makeModule()
        XCTAssertEqual(module.initialKeyRepeat, 14,
            "Persisted 25 (out of 5...14) must clamp to 14 on load")
        XCTAssertEqual(module.keyRepeat, 5,
            "Persisted 6 (out of 1...5) must clamp to 5 on load")
    }

    // MARK: - Test 6: restoreMacOSDefaults()

    func testRestoreMacOSDefaults() {
        let module = makeModule()
        module.isEnabled = true
        module.initialKeyRepeat = 10
        module.keyRepeat = 3
        let applyCallsBeforeRestore = spy.applyCalls.count
        let restoreCallsBeforeRestore = spy.restoreCalls
        let liveHIDCallsBeforeRestore = spy.liveHIDCalls.count
        let restorePressAndHoldCallsBeforeRestore = spy.restorePressAndHoldCalls
        let disablePressAndHoldCallsBeforeRestore = spy.disablePressAndHoldCalls

        module.restoreMacOSDefaults()

        XCTAssertEqual(module.initialKeyRepeat, 14,
            "Restore must land the slider on the range maximum (14) — true default 25 is outside the selectable range")
        XCTAssertEqual(module.keyRepeat, 5,
            "Restore must land the slider on the range maximum (5) — true default 6 is outside the selectable range")
        XCTAssertEqual(spy.restoreCalls, restoreCallsBeforeRestore + 1,
            "Restore must delete the global keys via applier.restoreSystemDefaults()")
        XCTAssertEqual(spy.applyCalls.count, applyCallsBeforeRestore,
            "Restore must NOT re-apply values — deleting the keys IS the restore")
        XCTAssertEqual(spy.liveHIDCalls.count, liveHIDCallsBeforeRestore + 1,
            "Restore must revert live HID to macOS defaults for immediate effect")
        XCTAssertEqual(spy.liveHIDCalls.last?.initialKeyRepeatNs, 416_666_667)
        XCTAssertEqual(spy.liveHIDCalls.last?.keyRepeatNs, 100_000_000)
        XCTAssertEqual(spy.restorePressAndHoldCalls, restorePressAndHoldCallsBeforeRestore + 1,
            "Restore must delete ApplePressAndHoldEnabled exactly once so the accent picker returns")
        XCTAssertEqual(spy.disablePressAndHoldCalls, disablePressAndHoldCallsBeforeRestore,
            "Restore must NOT re-disable press-and-hold")
    }

    // MARK: - Test 7: Tick conversions (1/60 s per tick)

    func testNanosecondsForTicks() {
        XCTAssertEqual(KeyRepeatModule.nanoseconds(forTicks: 25), 416_666_667)
        XCTAssertEqual(KeyRepeatModule.nanoseconds(forTicks: 6), 100_000_000)
        XCTAssertEqual(KeyRepeatModule.nanoseconds(forTicks: 15), 250_000_000)
        XCTAssertEqual(KeyRepeatModule.nanoseconds(forTicks: 2), 33_333_333)
        XCTAssertEqual(KeyRepeatModule.nanoseconds(forTicks: 5), 83_333_333)
    }

    func testMillisecondsForTicks() {
        XCTAssertEqual(KeyRepeatModule.milliseconds(forTicks: 15), 250,
            "15 ticks = 250 ms — a tick is 1/60 s, NOT 15 ms")
        XCTAssertEqual(KeyRepeatModule.milliseconds(forTicks: 2), 33)
        XCTAssertEqual(KeyRepeatModule.milliseconds(forTicks: 25), 417)
        XCTAssertEqual(KeyRepeatModule.milliseconds(forTicks: 6), 100)
        XCTAssertEqual(KeyRepeatModule.milliseconds(forTicks: 14), 233,
            "New initial-delay slider maximum readout")
        XCTAssertEqual(KeyRepeatModule.milliseconds(forTicks: 5), 83,
            "New repeat-rate slider maximum readout")
    }

    func testMacOSDefaultLiveHIDConstants() {
        XCTAssertEqual(KeyRepeatModule.macOSDefaultInitialKeyRepeatNs, 416_666_667)
        XCTAssertEqual(KeyRepeatModule.macOSDefaultKeyRepeatNs, 100_000_000)
    }
}
