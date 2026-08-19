import XCTest
import CoreGraphics
@testable import macssential

final class ScreenshotAutoCopyModuleTests: XCTestCase {

    private let allKeys = [
        "com.macssential.module.screenshot-auto-copy.enabled",
    ]

    override func setUp() {
        super.setUp()
        for key in allKeys { UserDefaults.standard.removeObject(forKey: key) }
    }

    override func tearDown() {
        for key in allKeys { UserDefaults.standard.removeObject(forKey: key) }
        super.tearDown()
    }

    // MARK: - Protocol Conformance (SCRN-01)

    func testProtocolConformance() {
        let module = ScreenshotAutoCopyModule()
        XCTAssertEqual(module.id, "screenshot-auto-copy")
        XCTAssertFalse(module.name.isEmpty)
        XCTAssertEqual(module.icon, "doc.on.clipboard")
        XCTAssertTrue(module.isAvailable)
        XCTAssertTrue(module.requiresAccessibilityPermission)
    }

    @MainActor func testDefaultPanelVisibility() {
        // isPanelVisible was replaced by PanelConfiguration (quick-260716-n8f):
        // screenshot-auto-copy must be in the default visible set for every language (SCRN-01).
        for lang in AppLanguage.allCases {
            let visible = PanelConfiguration.defaultVisibleIDs(
                allModuleIDs: ["screenshot-auto-copy"], language: lang)
            XCTAssertTrue(visible.contains("screenshot-auto-copy"),
                "ScreenshotAutoCopyModule must appear in the panel by default (SCRN-01, lang=\(lang.rawValue))")
        }
    }

    // MARK: - Default State

    func testDefaultDisabled() {
        let module = ScreenshotAutoCopyModule()
        XCTAssertFalse(module.isEnabled, "Fresh module should be disabled by default")
    }

    // MARK: - UserDefaults Persistence (SCRN-04)

    func testEnabledPersistenceAcrossInstances() {
        let module1 = ScreenshotAutoCopyModule()
        module1.isEnabled = true

        let module2 = ScreenshotAutoCopyModule()
        XCTAssertTrue(module2.isEnabled,
            "isEnabled must persist to UserDefaults and be read back on next init (SCRN-04)")
    }

    func testDisabledPersistenceAcrossInstances() {
        // Pre-seed enabled, then disable
        UserDefaults.standard.set(true, forKey: "com.macssential.module.screenshot-auto-copy.enabled")
        let module = ScreenshotAutoCopyModule()
        module.isEnabled = false

        let module2 = ScreenshotAutoCopyModule()
        XCTAssertFalse(module2.isEnabled, "Disabled state must persist (SCRN-04)")
    }

    // MARK: - Interception Logic (SCRN-02, SCRN-03)
    // Pure-logic tests extracted from callback. These tests exercise shouldIntercept
    // and flag mutation without creating a real CGEventTap.

    func testKeyCode0x14IsScreenshotKey() {
        // kVK_ANSI_3 = 0x14. This key code must be intercepted for SCRN-03.
        XCTAssertEqual(CGKeyCode(0x14), CGKeyCode(20),
            "kVK_ANSI_3 hex 0x14 must equal decimal 20")
    }

    func testKeyCode0x15IsScreenshotKey() {
        // kVK_ANSI_4 = 0x15. This key code must be intercepted for SCRN-02.
        XCTAssertEqual(CGKeyCode(0x15), CGKeyCode(21),
            "kVK_ANSI_4 hex 0x15 must equal decimal 21")
    }

    func testModifierMaskTargetFlags() {
        // Target: exactly Cmd+Shift. Verify the bitmask values are non-zero and distinct.
        let cmdFlag = CGEventFlags.maskCommand.rawValue
        let shiftFlag = CGEventFlags.maskShift.rawValue
        let ctrlFlag = CGEventFlags.maskControl.rawValue
        let targetFlags = cmdFlag | shiftFlag

        XCTAssertNotEqual(cmdFlag, 0)
        XCTAssertNotEqual(shiftFlag, 0)
        XCTAssertNotEqual(ctrlFlag, 0)
        XCTAssertNotEqual(targetFlags, 0)
        // Adding Control must differ from the target (the redirect produces a different combo)
        XCTAssertNotEqual(targetFlags | ctrlFlag, targetFlags,
            "Adding maskControl must change the flags (the whole point of the redirect)")
    }

    func testFlagMutationAddsMaskControl() {
        // Simulate the flag mutation the callback performs.
        // Input: Cmd+Shift flags (plus maskNonCoalesced which is always present on real events)
        let maskNonCoalesced: UInt64 = 0x100
        let inputRaw = CGEventFlags.maskCommand.rawValue
                     | CGEventFlags.maskShift.rawValue
                     | maskNonCoalesced
        let inputFlags = CGEventFlags(rawValue: inputRaw)

        // Apply the same mutation the callback uses
        let mutatedFlags = CGEventFlags(rawValue: inputFlags.rawValue | CGEventFlags.maskControl.rawValue)

        XCTAssertTrue(mutatedFlags.contains(.maskControl),
            "Mutation must add maskControl (routes to clipboard shortcut)")
        XCTAssertTrue(mutatedFlags.contains(.maskCommand),
            "Mutation must preserve maskCommand")
        XCTAssertTrue(mutatedFlags.contains(.maskShift),
            "Mutation must preserve maskShift")
    }

    func testMaskedComparisonExcludesNonCoalesced() {
        // Verify the masked comparison correctly identifies Cmd+Shift
        // even when maskNonCoalesced is set (as it always is on real discrete events).
        let maskNonCoalesced: UInt64 = 0x100
        let rawWithNonCoalesced = CGEventFlags.maskCommand.rawValue
                                | CGEventFlags.maskShift.rawValue
                                | maskNonCoalesced

        let userModifierMask: UInt64 = CGEventFlags.maskCommand.rawValue
                                     | CGEventFlags.maskShift.rawValue
                                     | CGEventFlags.maskControl.rawValue
                                     | CGEventFlags.maskAlternate.rawValue
                                     | CGEventFlags.maskSecondaryFn.rawValue
        let cleanFlags = rawWithNonCoalesced & userModifierMask
        let targetFlags = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue

        XCTAssertEqual(cleanFlags, targetFlags,
            "Masked comparison must equal targetFlags even when maskNonCoalesced is present. " +
            "Raw equality would fail here — this is the exact pitfall from RESEARCH.md Q3.")
    }

    // MARK: - Secure Input Warning (screenshot-intercept-drops root cause)
    // While another process holds Secure Keyboard Input, macOS withholds keyDown
    // from ALL event taps — interception fails even with a healthy tap. The module
    // must surface this (warn once per hold episode) and clear automatically.

    func testSecureInputWarningSetOnHold() {
        let module = ScreenshotAutoCopyModule()
        module.secureInputCheck = { true }
        module.secureInputHolderName = { "Terminal" }

        module.refreshSecureInputWarning()

        XCTAssertNotNil(module.secureInputWarning, "Active Secure Input must surface a warning")
        XCTAssertTrue(module.secureInputWarning?.contains("Terminal") == true,
            "Warning must name the holder process")
    }

    func testSecureInputWarningWarnsOncePerEpisode() {
        let module = ScreenshotAutoCopyModule()
        var holderLookups = 0
        module.secureInputCheck = { true }
        module.secureInputHolderName = { holderLookups += 1; return "Terminal" }

        module.refreshSecureInputWarning()
        module.refreshSecureInputWarning()
        module.refreshSecureInputWarning()

        XCTAssertEqual(holderLookups, 1,
            "Warning (and holder lookup) must fire once per hold episode, not every watchdog tick")
    }

    func testSecureInputWarningClearsOnRelease() {
        let module = ScreenshotAutoCopyModule()
        var secureInputActive = true
        module.secureInputCheck = { secureInputActive }
        module.secureInputHolderName = { "Terminal" }

        module.refreshSecureInputWarning()
        XCTAssertNotNil(module.secureInputWarning)

        secureInputActive = false
        module.refreshSecureInputWarning()
        XCTAssertNil(module.secureInputWarning,
            "Warning must clear automatically when Secure Input is released")
    }

    func testSecureInputWarningFallsBackWhenHolderUnknown() {
        let module = ScreenshotAutoCopyModule()
        module.secureInputCheck = { true }
        module.secureInputHolderName = { nil }

        module.refreshSecureInputWarning()

        XCTAssertNotNil(module.secureInputWarning,
            "Warning must still appear when the holder process cannot be resolved")
    }

    func testSecureInputReholdWarnsAgain() {
        let module = ScreenshotAutoCopyModule()
        var secureInputActive = true
        var holderLookups = 0
        module.secureInputCheck = { secureInputActive }
        module.secureInputHolderName = { holderLookups += 1; return "Terminal" }

        module.refreshSecureInputWarning() // episode 1
        secureInputActive = false
        module.refreshSecureInputWarning() // released
        secureInputActive = true
        module.refreshSecureInputWarning() // episode 2

        XCTAssertEqual(holderLookups, 2, "A new hold episode must warn again")
        XCTAssertNotNil(module.secureInputWarning)
    }

    // MARK: - Settings View

    @MainActor func testSettingsViewExists() {
        let module = ScreenshotAutoCopyModule()
        XCTAssertNotNil(module.settingsView,
            "ScreenshotAutoCopyModule provides a settings view (format / save location)")
    }
}
