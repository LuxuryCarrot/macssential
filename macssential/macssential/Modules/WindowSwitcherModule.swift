import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import SwiftUI

/// Windows-style Cmd+Tab: cycles individual windows of every running app instead
/// of cycling apps, which is what macOS does natively.
///
/// Shape mirrors `ScreenshotAutoCopyModule` (session CGEventTap + health watchdog +
/// Secure Input surfacing) because those failure modes are identical for any
/// keyboard-intercepting module in this app.
///
/// Two deliberate constraints drive the design:
/// 1. The tap callback does zero Accessibility or UI work. Enumerating every app's
///    windows takes milliseconds; doing that inside the callback risks
///    `tapDisabledByTimeout`, which drops keyboard input system-wide. All AX work
///    is deferred to the main queue and late keystrokes are queued in `SwitcherSession`.
/// 2. Window titles come from the Accessibility API, never from `kCGWindowName`.
///    Since macOS 10.15 `kCGWindowName` is withheld unless the app holds Screen
///    Recording permission, which macssential deliberately never requests. AX titles
///    only need Accessibility, which this module already requires.
@Observable
final class WindowSwitcherModule: FeatureModule, @unchecked Sendable {
    let id = "window-switcher"
    var name: String { String(localized: "module.window_switcher.name") }
    var moduleDescription: String { String(localized: "module.window_switcher.description") }
    let icon = "macwindow.on.rectangle"
    let isAvailable = true
    let requiresAccessibilityPermission = true

    /// kVK_Tab
    static let tabKeyCode: CGKeyCode = 0x30
    /// kVK_Escape
    static let escapeKeyCode: CGKeyCode = 0x35
    /// kVK_LeftArrow
    static let leftArrowKeyCode: CGKeyCode = 0x7B
    /// kVK_RightArrow
    static let rightArrowKeyCode: CGKeyCode = 0x7C
    /// kVK_DownArrow
    static let downArrowKeyCode: CGKeyCode = 0x7D
    /// kVK_UpArrow
    static let upArrowKeyCode: CGKeyCode = 0x7E

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "com.macssential.module.window-switcher.enabled")
            if isEnabled { activate() } else { deactivate() }
        }
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapWatchdogTimer: Timer?
    private var wakeObserver: NSObjectProtocol?

    /// App-activation observer that keeps the thumbnail service's window list warm.
    /// Only ever touched inside `@MainActor` methods.
    private var prewarmObserver: NSObjectProtocol?

    /// One Cmd-held switching episode. Only ever touched from the main run loop:
    /// the tap callback runs there, and every follow-up is dispatched to main.
    private let session = SwitcherSession()

    /// Created on first use so a module that is never triggered never allocates a
    /// panel. Only ever touched inside `@MainActor` methods.
    private var overlay: WindowSwitcherOverlayController?

    /// Also created on first use: allocating it eagerly would be harmless (it never
    /// prompts) but pointless for a module that is never triggered. Only ever
    /// touched inside `@MainActor` methods.
    private var thumbnails: WindowThumbnailService?

    /// User-facing warning shown while another process holds Secure Keyboard Input.
    /// macOS withholds keyDown from ALL event taps for the duration, so Cmd+Tab
    /// interception silently stops working even with a healthy tap and granted
    /// permission. Surfacing it is the only available remedy.
    private(set) var secureInputWarning: String?

    /// True when CGEvent.tapCreate returned nil — the toggle is on but nothing is
    /// intercepting. Surfaced in the settings view instead of failing silently.
    private(set) var tapCreationFailed = false

    /// Injectable for tests. Defaults to the real Carbon API.
    var secureInputCheck: () -> Bool = { IsSecureEventInputEnabled() }

    /// Injectable for tests. Reuses the screenshot module's IOKit resolver rather
    /// than duplicating it — the holder lookup is process-wide, not module-specific.
    var secureInputHolderName: () -> String? = { ScreenshotAutoCopyModule.resolveSecureInputHolderName() }

    init() {
        self.isEnabled = UserDefaults.standard.bool(forKey: "com.macssential.module.window-switcher.enabled")
    }

    func activate() {
        guard AXIsProcessTrusted() else { return }
        startEventTap()
        startTapWatchdog()
        onMain { $0.startPrewarmObserver() }
        refreshSecureInputWarning()
    }

    func deactivate() {
        session.cancel()
        onMain {
            $0.dismissOverlay()
            $0.stopPrewarmObserver()
            // Disabling the module (or losing permission) must leave no captured
            // pixels behind — T-I8L-01.
            $0.thumbnails?.purge()
        }
        stopTapWatchdog()
        stopEventTap()
        secureInputWarning = nil
        tapCreationFailed = false
    }

    /// Live-resource module: quit and permission revocation must tear the tap down,
    /// otherwise a disabled-but-registered tap lingers in the window server.
    func releaseResources() {
        deactivate()
    }

    @MainActor var settingsView: AnyView? {
        AnyView(WindowSwitcherSettingsView(module: self))
    }

    // MARK: - Interception Predicates
    // Static so the interception rules are unit-testable without a real tap.

    /// Modifier bits a user can actually press. Real keyboard events also carry
    /// maskNonCoalesced (and device-dependent bits), so raw flag equality never
    /// matches — everything outside this mask is stripped before comparing.
    private static let userModifierMask: UInt64 =
        CGEventFlags.maskCommand.rawValue
        | CGEventFlags.maskShift.rawValue
        | CGEventFlags.maskControl.rawValue
        | CGEventFlags.maskAlternate.rawValue
        | CGEventFlags.maskSecondaryFn.rawValue

    /// True only for exactly Cmd+Tab or Cmd+Shift+Tab. Any additional modifier
    /// belongs to a different shortcut and must pass through untouched.
    static func shouldHandleTab(flags: CGEventFlags, keyCode: CGKeyCode) -> Bool {
        guard keyCode == tabKeyCode else { return false }
        let clean = flags.rawValue & userModifierMask
        let command = CGEventFlags.maskCommand.rawValue
        let commandShift = command | CGEventFlags.maskShift.rawValue
        return clean == command || clean == commandShift
    }

    /// Maps an arrow key code to a grid direction, or nil for every other key.
    ///
    /// Deliberately a pure key-code switch with no flag inspection: it is the only
    /// new work the tap callback performs, and the callback must stay in the
    /// microsecond range (T-I8L-02). The decision to *act* on the direction is the
    /// caller's, gated on an already-active session.
    static func arrowDirection(keyCode: CGKeyCode) -> WindowSwitcherEngine.GridDirection? {
        switch keyCode {
        case leftArrowKeyCode: return .left
        case rightArrowKeyCode: return .right
        case downArrowKeyCode: return .down
        case upArrowKeyCode: return .up
        default: return nil
        }
    }

    /// Shift alongside Cmd reverses the cycling direction.
    static func isBackward(flags: CGEventFlags) -> Bool {
        flags.contains(.maskCommand) && flags.contains(.maskShift)
    }

    /// Releasing Cmd is the commit trigger; releasing Shift alone is not.
    static func commandReleased(flags: CGEventFlags) -> Bool {
        !flags.contains(.maskCommand)
    }

    // MARK: - CGEventTap Lifecycle

    private func startEventTap() {
        stopEventTap()

        // flagsChanged is needed alongside keyDown: the commit trigger is the Cmd
        // release, which never produces a keyDown.
        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
                                   | (1 << CGEventType.flagsChanged.rawValue)

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: Self.keyboardCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let eventTap else {
            NSLog("[macssential] WindowSwitcherModule: CGEvent.tapCreate returned nil — keyboard interception unavailable")
            tapCreationFailed = true
            return
        }
        tapCreationFailed = false

        runLoopSource = CFMachPortCreateRunLoopSource(nil, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    private func stopEventTap() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            // Without an explicit invalidate, the window server keeps the tap
            // registered as a disabled zombie after the CFMachPort is released.
            CFMachPortInvalidate(eventTap)
        }
        eventTap = nil
        runLoopSource = nil
    }

    // MARK: - Tap Health Watchdog

    /// macOS silently disables session taps over long uptime — sleep/wake cycles,
    /// secure-input sessions, or window server stress. The in-callback
    /// tapDisabledBy* recovery only fires when that notification is actually
    /// delivered; when the tap dies without one, Cmd+Tab stays broken until the
    /// tap is recreated. This re-checks periodically and on wake.
    private func startTapWatchdog() {
        stopTapWatchdog()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.ensureTapHealthy()
        }
        tapWatchdogTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.ensureTapHealthy()
        }
    }

    private func stopTapWatchdog() {
        tapWatchdogTimer?.invalidate()
        tapWatchdogTimer = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    /// Re-enables a disabled tap, or recreates it when the mach port is invalid or
    /// re-enabling is refused. Cheap when healthy (one state query).
    private func ensureTapHealthy() {
        guard isEnabled else { return }
        // Secure Input blocks keyDown delivery regardless of tap health or
        // permission — check it independently of the AX guard.
        refreshSecureInputWarning()
        guard AXIsProcessTrusted() else { return }
        guard let eventTap else {
            startEventTap()
            return
        }
        if !CFMachPortIsValid(eventTap) {
            startEventTap()
            return
        }
        if !CGEvent.tapIsEnabled(tap: eventTap) {
            CGEvent.tapEnable(tap: eventTap, enable: true)
            if !CGEvent.tapIsEnabled(tap: eventTap) {
                startEventTap()
            }
        }
    }

    // MARK: - Secure Input Detection

    /// Warn-once semantics: the message is produced only on the inactive→active
    /// transition, not on every watchdog tick.
    func refreshSecureInputWarning() {
        let active = secureInputCheck()
        if active {
            guard secureInputWarning == nil else { return } // already warned this episode
            let holder = secureInputHolderName()
                ?? String(localized: "module.window_switcher.secure_input_unknown_app")
            secureInputWarning = String(
                format: String(localized: "module.window_switcher.secure_input_warning"),
                holder
            )
            NSLog("[macssential] WindowSwitcherModule: Secure Input held by %@ — keyDown events are withheld from event taps; Cmd+Tab interception paused", holder)
        } else if secureInputWarning != nil {
            secureInputWarning = nil
            NSLog("[macssential] WindowSwitcherModule: Secure Input released — Cmd+Tab interception resumed")
        }
    }

    // MARK: - Static Callback

    /// Runs on the main run loop (the tap source is added there), and must return
    /// in microseconds — see the type-level note about tapDisabledByTimeout.
    private static let keyboardCallback: CGEventTapCallBack = {
        _, type, event, userInfo in

        // tapDisabledByUserInput is also what permission revocation delivers;
        // re-enabling without the AX check would keep a blocking tap alive.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let userInfo, AXIsProcessTrusted() {
                let module = Unmanaged<WindowSwitcherModule>
                    .fromOpaque(userInfo).takeUnretainedValue()
                if let tap = module.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
            }
            return Unmanaged.passUnretained(event)
        }

        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let module = Unmanaged<WindowSwitcherModule>.fromOpaque(userInfo).takeUnretainedValue()

        switch type {
        case .keyDown:
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

            if shouldHandleTab(flags: event.flags, keyCode: keyCode) {
                let backward = isBackward(flags: event.flags)
                if module.session.isActive {
                    module.session.advance(backward: backward)
                    module.onMain { $0.refreshOverlaySelection() }
                } else {
                    module.session.beginPending(backward: backward)
                    module.onMain { $0.loadWindows() }
                }
                // Consume: macOS must never show its own app switcher underneath ours.
                return nil
            }

            // Arrows are claimed ONLY while a session is live, which is only ever
            // true while Cmd is held after Cmd+Tab. Every arrow press outside that
            // window fails the first check and passes straight through (T-I8L-03).
            // No flag test is needed or wanted: `isActive` is both the correct
            // condition and the cheapest one.
            if module.session.isActive, let direction = arrowDirection(keyCode: keyCode) {
                module.onMain { $0.moveSelection(direction) }
                // Consume: mid-session arrows must not also scroll the app behind
                // the overlay.
                return nil
            }

            if keyCode == escapeKeyCode && module.session.isActive {
                module.session.cancel()
                module.onMain { $0.dismissOverlay() }
                return nil
            }
            return Unmanaged.passUnretained(event)

        case .flagsChanged:
            // Never consumed — modifier state must keep flowing to every other app.
            if module.session.isActive && commandReleased(flags: event.flags) {
                module.onMain { $0.commitSelection() }
            }
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// Defers work to the main queue. `DispatchQueue.main.async` (not `Task`) so
    /// blocks stay strictly FIFO — a queued Tab must never overtake the
    /// enumeration it was queued behind.
    private func onMain(_ work: @escaping @MainActor (WindowSwitcherModule) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated { work(self) }
        }
    }

    // MARK: - Window Enumeration

    @MainActor
    fileprivate func loadWindows() {
        session.begin(windows: enumerateWindows())
        let overlay = overlay ?? {
            let created = WindowSwitcherOverlayController()
            self.overlay = created
            return created
        }()

        // Mouse and keyboard drive the SAME selection state, so hovering then
        // pressing Tab continues from the hovered tile. Clicking reuses
        // commitSelection(), which means there is exactly one raise path in this
        // module regardless of how the target was chosen.
        overlay.onHoverIndex = { [weak self] index in
            guard let self else { return }
            session.select(index: index)
            refreshOverlaySelection()
        }
        overlay.onActivateIndex = { [weak self] index in
            guard let self else { return }
            session.select(index: index)
            commitSelection()
        }

        overlay.show(windows: session.windows, selectedIndex: session.selectedIndex)

        // Thumbnails are strictly an enhancement layered on top of an already
        // usable overlay: without Screen Recording this returns immediately and the
        // tiles keep their app icons.
        let service = ensureThumbnailService()
        service.beginSession()
        service.requestThumbnails(for: session.windows) { [weak overlay] id, image in
            overlay?.setThumbnail(image, for: id)
        }
    }

    // MARK: - Thumbnail Pre-warm

    /// Keeps the thumbnail service's window list warm off an event the user caused.
    ///
    /// Enumerating shareable windows is the expensive half of producing a thumbnail,
    /// and app activation is both a strong hint that the window set just changed and
    /// a moment the user is already waiting through. No timer runs while idle, the
    /// service throttles itself to one refresh per 10 s, and it refreshes metadata
    /// only — no pixels are captured here (T-I8L-05).
    @MainActor
    fileprivate func startPrewarmObserver() {
        stopPrewarmObserver()
        prewarmObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // Not `ensureThumbnailService()`: pre-warming must never be the
                // reason the service exists. It also self-gates on the current
                // Screen Recording answer, so a revocation stops this immediately.
                self?.thumbnails?.prewarm()
            }
        }
    }

    @MainActor
    fileprivate func stopPrewarmObserver() {
        if let prewarmObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(prewarmObserver)
            self.prewarmObserver = nil
        }
    }

    @MainActor
    private func ensureThumbnailService() -> WindowThumbnailService {
        if let thumbnails { return thumbnails }
        let created = WindowThumbnailService()
        thumbnails = created
        return created
    }

    /// Screen Recording status, read without prompting. Drives the optional hint in
    /// the settings row.
    @MainActor
    var screenRecordingGranted: Bool {
        ensureThumbnailService().hasPermission
    }

    /// The user-initiated permission request. Reached only from the explicit button
    /// in the settings row — never automatically (T-HGV-02).
    @MainActor
    func requestScreenRecordingPermission() {
        ensureThumbnailService().requestPermission()
    }

    /// Applies one arrow step. Uses the overlay's own column count so the navigation
    /// model and the drawn grid can never drift apart.
    @MainActor
    fileprivate func moveSelection(_ direction: WindowSwitcherEngine.GridDirection) {
        session.move(direction, columns: WindowSwitcherOverlayView.maxColumns)
        refreshOverlaySelection()
    }

    /// Repaints the highlight after a Tab. Never creates the controller: a stray
    /// advance without a preceding session start must not open a panel.
    @MainActor
    fileprivate func refreshOverlaySelection() {
        overlay?.updateSelection(windows: session.windows, selectedIndex: session.selectedIndex)
    }

    /// Single teardown point for the overlay AND the capture session, so every exit
    /// path (Esc, Cmd release, click, module disable) drops captured pixels
    /// (T-HGV-01) without each caller having to remember to.
    @MainActor
    fileprivate func dismissOverlay() {
        overlay?.dismiss()
        thumbnails?.endSession()
    }

    private func enumerateWindows() -> [SwitcherWindow] {
        let ownPID = getpid()
        let appOrder = Self.appFrontToBackOrder()
        var raw: [SwitcherWindow] = []

        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier != ownPID {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            var value: CFTypeRef?
            // One attempt only: a non-success AXError here means the app is
            // unresponsive or AX-hostile, and retrying would stall the overlay.
            guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else { continue }

            let ownerName = app.localizedName ?? ""
            // Apps absent from the on-screen list sort last rather than first.
            let zOrder = appOrder[app.processIdentifier] ?? Int.max

            for (index, window) in windows.enumerated() {
                // Sheets, popovers and drawers also live in kAXWindowsAttribute;
                // only AXWindow is a switchable target.
                guard Self.stringAttribute(window, kAXRoleAttribute) == kAXWindowRole else { continue }
                raw.append(SwitcherWindow(
                    pid: app.processIdentifier,
                    ownerName: ownerName,
                    title: Self.stringAttribute(window, kAXTitleAttribute) ?? "",
                    axIndex: index,
                    zOrder: zOrder,
                    isMinimized: Self.boolAttribute(window, kAXMinimizedAttribute) ?? false
                ))
            }
        }

        return WindowSwitcherEngine.filterAndOrder(raw, excludingPID: ownPID)
    }

    /// Front-to-back order of apps, keyed by pid.
    ///
    /// `CGWindowListCopyWindowInfo` returns on-screen windows in front-to-back
    /// order, and pid/bounds/layer are readable without Screen Recording permission
    /// (only `kCGWindowName` is gated). First appearance of a pid therefore gives
    /// that app's depth; windows within an app keep their AX order, which is
    /// already front-to-back.
    private static func appFrontToBackOrder() -> [pid_t: Int] {
        guard let infoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [:] }

        var order: [pid_t: Int] = [:]
        var next = 0
        for info in infoList {
            guard let pidNumber = info[kCGWindowOwnerPID as String] as? pid_t else { continue }
            if order[pidNumber] == nil {
                order[pidNumber] = next
                next += 1
            }
        }
        return order
    }

    // MARK: - Activation

    @MainActor
    fileprivate func commitSelection() {
        // The overlay comes down whether or not a target survived re-resolution.
        defer { dismissOverlay() }
        guard let target = session.commit() else { return }
        raise(target)
    }

    /// Re-resolves the live AXUIElement before raising: the window list can shift
    /// while the overlay is open (an app opening or closing a window), so the
    /// captured index alone is not trustworthy.
    private func raise(_ target: SwitcherWindow) {
        let appElement = AXUIElementCreateApplication(target.pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement], !windows.isEmpty else { return }

        let element: AXUIElement?
        if windows.indices.contains(target.axIndex),
           Self.stringAttribute(windows[target.axIndex], kAXTitleAttribute) == target.title {
            element = windows[target.axIndex]
        } else if let match = windows.first(where: {
            Self.stringAttribute($0, kAXTitleAttribute) == target.title
        }) {
            element = match
        } else if windows.indices.contains(target.axIndex) {
            element = windows[target.axIndex]
        } else {
            element = nil
        }
        guard let window = element else { return }

        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        // Some apps reject a focused-window write; raising already worked, so the
        // failure is ignored rather than aborting the switch.
        AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, window)
        NSRunningApplication(processIdentifier: target.pid)?.activate()
    }

    // MARK: - AX Attribute Helpers

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func boolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? Bool
    }
}
