import XCTest
import CoreGraphics
@testable import macssential

/// Module-level coverage for the Window Switcher (QUICK-F4Y-01..04).
/// No real CGEventTap is created here — the flag/key predicates are static so the
/// interception rules can be proven without touching the window server.
final class WindowSwitcherModuleTests: XCTestCase {

    private let allKeys = [
        "com.macssential.module.window-switcher.enabled",
    ]

    override func setUp() {
        super.setUp()
        for key in allKeys { UserDefaults.standard.removeObject(forKey: key) }
    }

    override func tearDown() {
        for key in allKeys { UserDefaults.standard.removeObject(forKey: key) }
        super.tearDown()
    }

    /// maskNonCoalesced is set on every real keyboard event; every predicate must
    /// tolerate it, which raw flag equality would not.
    private let maskNonCoalesced: UInt64 = 0x100

    // MARK: - Protocol Conformance (QUICK-F4Y-01)

    func testProtocolConformance() {
        let module = WindowSwitcherModule()
        XCTAssertEqual(module.id, "window-switcher")
        XCTAssertEqual(module.icon, "macwindow.on.rectangle")
        XCTAssertFalse(module.name.isEmpty, "Module name must be localized, not blank")
        XCTAssertFalse(module.moduleDescription.isEmpty, "Module description must be localized, not blank")
        XCTAssertTrue(module.isAvailable)
        XCTAssertTrue(module.requiresAccessibilityPermission,
            "The event tap and AX window raise both require Accessibility permission")
    }

    func testDefaultDisabled() {
        let module = WindowSwitcherModule()
        XCTAssertFalse(module.isEnabled,
            "Fresh module must be disabled — with it off, native Cmd+Tab is untouched")
    }

    func testEnabledPersistenceAcrossInstances() {
        let module1 = WindowSwitcherModule()
        module1.isEnabled = true

        let module2 = WindowSwitcherModule()
        XCTAssertTrue(module2.isEnabled,
            "isEnabled must persist to UserDefaults and be read back on next init (QUICK-F4Y-04)")
    }

    func testDisabledPersistenceAcrossInstances() {
        UserDefaults.standard.set(true, forKey: "com.macssential.module.window-switcher.enabled")
        let module = WindowSwitcherModule()
        module.isEnabled = false

        let module2 = WindowSwitcherModule()
        XCTAssertFalse(module2.isEnabled, "Disabled state must persist (QUICK-F4Y-04)")
    }

    @MainActor func testSettingsViewExists() {
        let module = WindowSwitcherModule()
        XCTAssertNotNil(module.settingsView,
            "WindowSwitcherModule provides a settings view (shortcut hint + warnings)")
    }

    @MainActor func testDefaultPanelVisibility() {
        for lang in AppLanguage.allCases {
            let visible = PanelConfiguration.defaultVisibleIDs(
                allModuleIDs: ["window-switcher"], language: lang)
            XCTAssertTrue(visible.contains("window-switcher"),
                "WindowSwitcherModule must appear in the panel by default (lang=\(lang.rawValue))")
        }
    }

    func testRegisteredInDefaultModuleRegistry() {
        let registry = ModuleRegistry()
        XCTAssertTrue(registry.modules.contains { $0.id == "window-switcher" },
            "ModuleRegistry() must register the Window Switcher so the panel renders its toggle (QUICK-F4Y-01)")
    }

    // MARK: - Key Codes (QUICK-F4Y-02)

    func testTabKeyCode() {
        // kVK_Tab = 0x30
        XCTAssertEqual(WindowSwitcherModule.tabKeyCode, CGKeyCode(48),
            "kVK_Tab hex 0x30 must equal decimal 48")
    }

    func testEscapeKeyCode() {
        // kVK_Escape = 0x35
        XCTAssertEqual(WindowSwitcherModule.escapeKeyCode, CGKeyCode(53),
            "kVK_Escape hex 0x35 must equal decimal 53")
    }

    // MARK: - Interception Predicates (QUICK-F4Y-02)

    func testCommandTabIsHandled() {
        let flags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | maskNonCoalesced)
        XCTAssertTrue(
            WindowSwitcherModule.shouldHandleTab(flags: flags, keyCode: WindowSwitcherModule.tabKeyCode),
            "Cmd+Tab is the switcher shortcut and must be intercepted even with maskNonCoalesced set")
    }

    func testCommandShiftTabIsHandled() {
        let flags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue
                                 | CGEventFlags.maskShift.rawValue | maskNonCoalesced)
        XCTAssertTrue(
            WindowSwitcherModule.shouldHandleTab(flags: flags, keyCode: WindowSwitcherModule.tabKeyCode),
            "Cmd+Shift+Tab cycles backward and must also be intercepted")
    }

    func testBareTabIsNotHandled() {
        let flags = CGEventFlags(rawValue: maskNonCoalesced)
        XCTAssertFalse(
            WindowSwitcherModule.shouldHandleTab(flags: flags, keyCode: WindowSwitcherModule.tabKeyCode),
            "Plain Tab must reach the focused app untouched")
    }

    func testControlTabIsNotHandled() {
        let flags = CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | maskNonCoalesced)
        XCTAssertFalse(
            WindowSwitcherModule.shouldHandleTab(flags: flags, keyCode: WindowSwitcherModule.tabKeyCode),
            "Ctrl+Tab is an app-level tab-cycling shortcut and must never be consumed")
    }

    func testCommandControlTabIsNotHandled() {
        let flags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue
                                 | CGEventFlags.maskControl.rawValue | maskNonCoalesced)
        XCTAssertFalse(
            WindowSwitcherModule.shouldHandleTab(flags: flags, keyCode: WindowSwitcherModule.tabKeyCode),
            "Extra modifiers beyond Cmd(+Shift) mean a different shortcut — pass it through")
    }

    func testCommandQIsNotHandled() {
        let flags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | maskNonCoalesced)
        XCTAssertFalse(
            WindowSwitcherModule.shouldHandleTab(flags: flags, keyCode: CGKeyCode(0x0C)),
            "Cmd+Q must not be swallowed by the switcher")
    }

    func testIsBackwardRequiresShift() {
        let forward = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | maskNonCoalesced)
        let backward = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue
                                    | CGEventFlags.maskShift.rawValue | maskNonCoalesced)
        XCTAssertFalse(WindowSwitcherModule.isBackward(flags: forward))
        XCTAssertTrue(WindowSwitcherModule.isBackward(flags: backward),
            "Shift alongside Cmd reverses the cycling direction")
    }

    func testIsBackwardRequiresCommand() {
        let shiftOnly = CGEventFlags(rawValue: CGEventFlags.maskShift.rawValue | maskNonCoalesced)
        XCTAssertFalse(WindowSwitcherModule.isBackward(flags: shiftOnly),
            "Shift without Cmd is not a switcher gesture at all")
    }

    func testCommandReleasedDetection() {
        let held = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | maskNonCoalesced)
        let released = CGEventFlags(rawValue: maskNonCoalesced)
        XCTAssertFalse(WindowSwitcherModule.commandReleased(flags: held),
            "While Cmd is held the overlay stays up")
        XCTAssertTrue(WindowSwitcherModule.commandReleased(flags: released),
            "Cmd release is the commit trigger")
    }

    func testShiftReleaseWhileCommandHeldIsNotACommit() {
        // Letting go of Shift mid-cycle must not raise the window.
        let stillHeld = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | maskNonCoalesced)
        XCTAssertFalse(WindowSwitcherModule.commandReleased(flags: stillHeld))
    }

    // MARK: - Secure Input Warning
    // While another process holds Secure Keyboard Input, macOS withholds keyDown
    // from ALL event taps — Cmd+Tab interception silently stops working.

    func testSecureInputWarningSetOnHold() {
        let module = WindowSwitcherModule()
        module.secureInputCheck = { true }
        module.secureInputHolderName = { "Terminal" }

        module.refreshSecureInputWarning()

        XCTAssertNotNil(module.secureInputWarning, "Active Secure Input must surface a warning")
        XCTAssertTrue(module.secureInputWarning?.contains("Terminal") == true,
            "Warning must name the holder process")
    }

    func testSecureInputWarningWarnsOncePerEpisode() {
        let module = WindowSwitcherModule()
        var holderLookups = 0
        module.secureInputCheck = { true }
        module.secureInputHolderName = { holderLookups += 1; return "Terminal" }

        module.refreshSecureInputWarning()
        module.refreshSecureInputWarning()
        module.refreshSecureInputWarning()

        XCTAssertEqual(holderLookups, 1,
            "Warning must fire once per hold episode, not on every watchdog tick")
    }

    func testSecureInputWarningClearsOnRelease() {
        let module = WindowSwitcherModule()
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
        let module = WindowSwitcherModule()
        module.secureInputCheck = { true }
        module.secureInputHolderName = { nil }

        module.refreshSecureInputWarning()

        XCTAssertNotNil(module.secureInputWarning,
            "Warning must still appear when the holder process cannot be resolved")
    }

    func testSecureInputReholdWarnsAgain() {
        let module = WindowSwitcherModule()
        var secureInputActive = true
        var holderLookups = 0
        module.secureInputCheck = { secureInputActive }
        module.secureInputHolderName = { holderLookups += 1; return "Terminal" }

        module.refreshSecureInputWarning()
        secureInputActive = false
        module.refreshSecureInputWarning()
        secureInputActive = true
        module.refreshSecureInputWarning()

        XCTAssertEqual(holderLookups, 2, "A new hold episode must warn again")
        XCTAssertNotNil(module.secureInputWarning)
    }

    // MARK: - Arrow Key Classification (QUICK-I8L-01)

    func testArrowKeyCodes() {
        // kVK_LeftArrow 0x7B, kVK_RightArrow 0x7C, kVK_DownArrow 0x7D, kVK_UpArrow 0x7E
        XCTAssertEqual(WindowSwitcherModule.leftArrowKeyCode, CGKeyCode(123))
        XCTAssertEqual(WindowSwitcherModule.rightArrowKeyCode, CGKeyCode(124))
        XCTAssertEqual(WindowSwitcherModule.downArrowKeyCode, CGKeyCode(125))
        XCTAssertEqual(WindowSwitcherModule.upArrowKeyCode, CGKeyCode(126))
    }

    func testArrowDirectionMapsEveryArrow() {
        XCTAssertEqual(
            WindowSwitcherModule.arrowDirection(keyCode: WindowSwitcherModule.leftArrowKeyCode), .left)
        XCTAssertEqual(
            WindowSwitcherModule.arrowDirection(keyCode: WindowSwitcherModule.rightArrowKeyCode), .right)
        XCTAssertEqual(
            WindowSwitcherModule.arrowDirection(keyCode: WindowSwitcherModule.downArrowKeyCode), .down)
        XCTAssertEqual(
            WindowSwitcherModule.arrowDirection(keyCode: WindowSwitcherModule.upArrowKeyCode), .up)
    }

    func testArrowDirectionIgnoresNonArrowKeys() {
        XCTAssertNil(WindowSwitcherModule.arrowDirection(keyCode: WindowSwitcherModule.tabKeyCode),
            "Tab has its own branch — classifying it as an arrow would double-handle it")
        XCTAssertNil(WindowSwitcherModule.arrowDirection(keyCode: WindowSwitcherModule.escapeKeyCode))
        XCTAssertNil(WindowSwitcherModule.arrowDirection(keyCode: CGKeyCode(0)),
            "kVK_ANSI_A must pass through untouched")
    }

    // MARK: - Session Arrow Navigation (QUICK-I8L-01)

    private func switcherWindows(_ count: Int) -> [SwitcherWindow] {
        (0..<count).map {
            SwitcherWindow(pid: 100, ownerName: "Safari", title: "Window \($0)",
                           axIndex: $0, zOrder: $0, isMinimized: false)
        }
    }

    func testSessionArrowsFollowTheGridTable() {
        let session = SwitcherSession()
        session.beginPending(backward: false)
        session.begin(windows: switcherWindows(7))
        XCTAssertEqual(session.selectedIndex, 1, "A forward opening press lands on the previous window")

        session.move(.down, columns: 5)
        XCTAssertEqual(session.selectedIndex, 6,
            "Column 1 has no tile in the short final row, so Down clamps to the last tile")

        session.move(.right, columns: 5)
        XCTAssertEqual(session.selectedIndex, 0, "Right on the last tile wraps like Tab")

        session.move(.up, columns: 5)
        XCTAssertEqual(session.selectedIndex, 0, "Up from the first row stays put")
    }

    func testSessionArrowSharesSelectionWithTabAndHover() {
        let session = SwitcherSession()
        session.beginPending(backward: false)
        session.begin(windows: switcherWindows(7))

        session.select(index: 4)      // mouse hover
        session.move(.right, columns: 5) // arrow
        XCTAssertEqual(session.selectedIndex, 5,
            "An arrow must continue from the hovered tile, not from a private cursor")

        session.advance(backward: false) // Tab
        XCTAssertEqual(session.selectedIndex, 6,
            "Tab must continue from where the arrow left off — one selection, three inputs")
    }

    func testSessionArrowBeforeWindowsLoadIsDropped() {
        let session = SwitcherSession()
        session.beginPending(backward: false)

        session.move(.down, columns: 5)
        XCTAssertEqual(session.selectedIndex, 0,
            "An arrow arriving before the list has no grid to move across and is discarded")

        session.begin(windows: switcherWindows(7))
        XCTAssertEqual(session.selectedIndex, 1,
            "The dropped arrow must not be replayed the way a queued Tab is")
    }

    func testSessionArrowOutsideASessionIsANoOp() {
        let session = SwitcherSession()
        session.move(.right, columns: 5)
        XCTAssertFalse(session.isActive)
        XCTAssertEqual(session.selectedIndex, 0)
    }
}
