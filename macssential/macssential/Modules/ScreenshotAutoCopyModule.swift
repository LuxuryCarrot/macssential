import CoreGraphics
import AppKit
import SwiftUI
import ApplicationServices

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
    }

    func deactivate() {
        clipboardObserverTimer?.invalidate()
        clipboardObserverTimer = nil
        stopEventTap()
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

        guard let eventTap else { return }

        runLoopSource = CFMachPortCreateRunLoopSource(nil, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    private func stopEventTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
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
