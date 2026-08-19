import CoreGraphics
import AppKit
import SwiftUI
import ApplicationServices
import Carbon
import IOKit

/// Intercepts Cmd+Shift+3/4 and adds the Control modifier, causing macOS to route
/// the screenshot to the clipboard instead of saving to a file.
///
/// Why flag mutation instead of event suppression + subprocess:
/// - Flag mutation lets macOS handle the actual capture, so no Screen Recording
///   permission is needed from macssential.
/// - Cmd+Shift+Ctrl+3/4 is macOS's built-in clipboard screenshot shortcut.
///
/// Folder save (when alsoSaveToFolder is true):
/// - Cmd+Shift+3: spawns a silent screencapture subprocess alongside the native capture.
/// - Cmd+Shift+4: after flag mutation macOS shows the crosshair ONCE; we then watch the
///   clipboard for the next image change and write it to the folder — no double crosshair.
@Observable
final class ScreenshotAutoCopyModule: FeatureModule, @unchecked Sendable {
    let id = "screenshot-auto-copy"
    var name: String { String(localized: "module.screenshot_auto_copy.name") }
    var moduleDescription: String { String(localized: "module.screenshot_auto_copy.description") }
    let icon = "doc.on.clipboard"
    let isAvailable = true
    let requiresAccessibilityPermission = true

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "com.macssential.module.screenshot-auto-copy.enabled")
            if isEnabled { activate() } else { deactivate() }
        }
    }

    var saveFolder: String {
        didSet {
            UserDefaults.standard.set(saveFolder, forKey: "com.macssential.module.screenshot-auto-copy.saveFolder")
        }
    }

    var alsoSaveToFolder: Bool {
        didSet {
            UserDefaults.standard.set(alsoSaveToFolder, forKey: "com.macssential.module.screenshot-auto-copy.alsoSaveToFolder")
        }
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var clipboardObserverTimer: Timer?
    private var tapWatchdogTimer: Timer?
    private var wakeObserver: NSObjectProtocol?

    /// User-facing warning shown while another process holds Secure Keyboard Input.
    /// While SecureEventInput is held, macOS withholds keyDown events from ALL
    /// CGEventTaps session-wide — interception silently fails even with a healthy
    /// tap and granted Accessibility permission (root cause of screenshot-intercept-drops).
    private(set) var secureInputWarning: String?

    /// True when CGEvent.tapCreate returned nil — interception is not running
    /// despite the toggle being on. Previously a silent failure.
    private(set) var tapCreationFailed = false

    /// Injectable for tests. Defaults to the real Carbon API.
    var secureInputCheck: () -> Bool = { IsSecureEventInputEnabled() }

    /// Injectable for tests. Resolves the localized name of the process holding
    /// Secure Input, or nil when it cannot be determined.
    var secureInputHolderName: () -> String? = { ScreenshotAutoCopyModule.resolveSecureInputHolderName() }

    init() {
        self.isEnabled = UserDefaults.standard.bool(forKey: "com.macssential.module.screenshot-auto-copy.enabled")
        // Priority: module-specific key → macOS system screenshot location → ~/Desktop
        let macOSLocation = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
        let defaultFolder = macOSLocation ?? (NSHomeDirectory() as NSString).appendingPathComponent("Desktop") as String
        self.saveFolder = UserDefaults.standard.string(forKey: "com.macssential.module.screenshot-auto-copy.saveFolder") ?? defaultFolder
        if UserDefaults.standard.object(forKey: "com.macssential.module.screenshot-auto-copy.alsoSaveToFolder") == nil {
            self.alsoSaveToFolder = true
        } else {
            self.alsoSaveToFolder = UserDefaults.standard.bool(forKey: "com.macssential.module.screenshot-auto-copy.alsoSaveToFolder")
        }
    }

    func activate() {
        guard AXIsProcessTrusted() else { return }
        startEventTap()
        startTapWatchdog()
        refreshSecureInputWarning()
    }

    func deactivate() {
        clipboardObserverTimer?.invalidate()
        clipboardObserverTimer = nil
        stopTapWatchdog()
        stopEventTap()
        secureInputWarning = nil
        tapCreationFailed = false
    }

    /// Live-resource module: quit/permission-revoke must stop the CGEventTap.
    func releaseResources() {
        deactivate()
    }

    @MainActor var settingsView: AnyView? {
        AnyView(ScreenshotAutoCopySettingsView(module: self))
    }

    // MARK: - CGEventTap Lifecycle

    private func startEventTap() {
        stopEventTap()

        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: Self.keyboardCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let eventTap else {
            // Previously a silent failure: the toggle stayed visually ON with no
            // interception running and no way for the user (or us) to know why.
            NSLog("[macssential] ScreenshotAutoCopyModule: CGEvent.tapCreate returned nil — keyboard interception unavailable")
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
            // Without an explicit invalidate, WindowServer keeps the tap registered
            // as a disabled zombie after the CFMachPort reference is released
            // (verified empirically via CGGetEventTapList).
            CFMachPortInvalidate(eventTap)
        }
        eventTap = nil
        runLoopSource = nil
    }

    // MARK: - Tap Health Watchdog

    /// macOS can silently disable a session CGEventTap over long uptime — sleep/wake
    /// cycles, secure-input sessions (lock-screen password fields), or WindowServer
    /// stress. The tapDisabledBy* recovery inside the callback only fires when that
    /// notification is actually delivered to a live tap; when the tap dies without it,
    /// interception stays broken until the tap is recreated (previously: only via a
    /// manual module toggle). This watchdog re-checks tap health periodically and on
    /// wake, re-enabling or recreating the tap as needed.
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

    /// Re-enables a disabled tap, or fully recreates it when the mach port is
    /// invalid or re-enabling is refused. Cheap when healthy (one state query).
    /// Skips work when permission is missing — the app-level permission poll
    /// handles revocation (releases taps) and restoration (reactivates modules).
    private func ensureTapHealthy() {
        guard isEnabled else { return }
        // Secure Input blocks keyDown delivery to ALL taps regardless of tap
        // health or permission — check it independently of the AX guard.
        refreshSecureInputWarning()
        guard AXIsProcessTrusted() else { return }
        guard let eventTap else {
            // Tap was never created (e.g., permission granted after activate) — create now.
            startEventTap()
            return
        }
        if !CFMachPortIsValid(eventTap) {
            // Port invalidated by the system — re-enable is impossible, recreate.
            startEventTap()
            return
        }
        if !CGEvent.tapIsEnabled(tap: eventTap) {
            CGEvent.tapEnable(tap: eventTap, enable: true)
            if !CGEvent.tapIsEnabled(tap: eventTap) {
                // Re-enable refused — tap is unrecoverable in place, recreate.
                startEventTap()
            }
        }
    }

    // MARK: - Secure Input Detection

    /// Updates `secureInputWarning` from the current Secure Keyboard Input state.
    /// While another process holds SecureEventInput (e.g., Terminal with a
    /// password prompt or a no-echo TUI, a stuck loginwindow session), macOS
    /// withholds keyDown events from every CGEventTap in the session — the
    /// interception fails even though the tap is healthy, permission is granted,
    /// and recreating the tap changes nothing. Surfacing this is the only fix;
    /// the hold clears when the offending app releases it.
    ///
    /// Warn-once semantics: the message (and log line) is produced only on the
    /// inactive→active transition, not on every watchdog tick.
    func refreshSecureInputWarning() {
        let active = secureInputCheck()
        if active {
            guard secureInputWarning == nil else { return } // already warned this episode
            let holder = secureInputHolderName()
                ?? String(localized: "module.screenshot_auto_copy.secure_input_unknown_app")
            secureInputWarning = String(
                format: String(localized: "module.screenshot_auto_copy.secure_input_warning"),
                holder
            )
            NSLog("[macssential] ScreenshotAutoCopyModule: Secure Input held by %@ — keyDown events are withheld from event taps; interception paused", holder)
        } else if secureInputWarning != nil {
            secureInputWarning = nil
            NSLog("[macssential] ScreenshotAutoCopyModule: Secure Input released — interception resumed")
        }
    }

    /// Resolves the app name of the process holding Secure Input by reading
    /// kCGSSessionSecureInputPID from the IOKit root entry's IOConsoleUsers
    /// property (same source `ioreg` shows). Returns nil when unresolvable.
    static func resolveSecureInputHolderName() -> String? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        guard let sessions = IORegistryEntryCreateCFProperty(
            root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? [[String: Any]] else { return nil }

        for session in sessions {
            guard let pid = session["kCGSSessionSecureInputPID"] as? Int else { continue }
            if let app = NSRunningApplication(processIdentifier: pid_t(pid)),
               let name = app.localizedName, !name.isEmpty {
                return name
            }
            var buffer = [CChar](repeating: 0, count: 1024)
            proc_name(pid_t(pid), &buffer, 1024)
            let name = String(cString: buffer)
            return name.isEmpty ? nil : name
        }
        return nil
    }

    // MARK: - Static Callback

    private static let keyboardCallback: CGEventTapCallBack = {
        proxy, type, event, userInfo in

        // tapDisabledByTimeout: re-enable (macOS disabled due to slow callback).
        // tapDisabledByUserInput: re-enable only if AX permission still granted —
        //   permission revocation sends this event; re-enabling without the check
        //   would keep the blocking tap alive and freeze system input.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let userInfo, AXIsProcessTrusted() {
                let module = Unmanaged<ScreenshotAutoCopyModule>
                    .fromOpaque(userInfo).takeUnretainedValue()
                if let tap = module.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        // Loop guard: Control already set means this is our redirected event
        // (or the user is intentionally pressing Ctrl). Pass through unmodified.
        guard !event.flags.contains(.maskControl) else { return Unmanaged.passUnretained(event) }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == 0x14 || keyCode == 0x15 else { return Unmanaged.passUnretained(event) }

        // Masked modifier check — must be exactly Cmd+Shift.
        // maskNonCoalesced is always present on real keyboard events so we strip
        // all non-modifier bits before comparing.
        let userModifierMask: UInt64 = CGEventFlags.maskCommand.rawValue
                                     | CGEventFlags.maskShift.rawValue
                                     | CGEventFlags.maskControl.rawValue
                                     | CGEventFlags.maskAlternate.rawValue
                                     | CGEventFlags.maskSecondaryFn.rawValue
        let cleanFlags = event.flags.rawValue & userModifierMask
        let targetFlags = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue
        guard cleanFlags == targetFlags else { return Unmanaged.passUnretained(event) }

        // Mutate flags: Cmd+Shift+3/4 → Cmd+Shift+Ctrl+3/4.
        // macOS routes Cmd+Shift+Ctrl+3/4 to clipboard instead of saving a file.
        // Returning the mutated event lets macOS handle the actual capture natively —
        // no Screen Recording permission needed from macssential.
        event.flags = CGEventFlags(rawValue: event.flags.rawValue | CGEventFlags.maskControl.rawValue)

        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let module = Unmanaged<ScreenshotAutoCopyModule>.fromOpaque(userInfo).takeUnretainedValue()
        let interactive = keyCode == 0x15

        if module.alsoSaveToFolder {
            DispatchQueue.main.async {
                if interactive {
                    // Cmd+Shift+4: macOS shows crosshair once via the mutated event above.
                    // Watch the clipboard for the next image and save it to the folder —
                    // avoids spawning a second screencapture process (no double crosshair).
                    module.startClipboardObserver()
                } else {
                    // Cmd+Shift+3: spawn a silent full-screen capture to the folder.
                    // This runs in parallel with the native clipboard capture — no conflict.
                    module.saveFullScreenToFolder()
                }
            }
        }

        return Unmanaged.passUnretained(event)
    }

    // MARK: - Folder Save Helpers

    private func saveFullScreenToFolder() {
        let path = folderPath()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", path]
        try? task.run()
    }

    /// Watches the clipboard for the next image change (set by macOS after the user
    /// finishes interactive region selection) and writes it to the save folder.
    /// Stops after 60 seconds to avoid leaking the timer if the user cancels.
    private func startClipboardObserver() {
        clipboardObserverTimer?.invalidate()
        let initialCount = NSPasteboard.general.changeCount
        var ticks = 0
        clipboardObserverTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            ticks += 1
            if ticks > 240 { timer.invalidate(); self.clipboardObserverTimer = nil; return }
            guard NSPasteboard.general.changeCount != initialCount else { return }
            timer.invalidate()
            self.clipboardObserverTimer = nil
            self.saveClipboardImageToFolder()
        }
    }

    private func saveClipboardImageToFolder() {
        guard let image = NSPasteboard.general.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage,
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else { return }
        let path = folderPath()
        try? pngData.write(to: URL(fileURLWithPath: path))
    }

    private func folderPath() -> String {
        let filename = "Screenshot \(Self.screenshotTimestamp()).png"
        return (saveFolder as NSString).appendingPathComponent(filename)
    }

    private static func screenshotTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: Date())
    }
}
