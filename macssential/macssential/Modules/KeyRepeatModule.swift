import SwiftUI

// MARK: - Global Preferences Applier

/// Abstracts writes to the macOS global preferences domain so tests can inject a spy
/// and never touch the user's real `.GlobalPreferences.plist`.
protocol GlobalKeyRepeatApplying {
    func apply(initialKeyRepeat: Int, keyRepeat: Int)
    func restoreSystemDefaults()
    /// Sets the session-live HID event system parameters (`HIDInitialKeyRepeat` /
    /// `HIDKeyRepeat`, in nanoseconds) so changes take effect immediately in all
    /// running apps — defaults writes alone only apply after re-login.
    func applyLiveHID(initialKeyRepeatNs: Int, keyRepeatNs: Int)
    /// Writes `ApplePressAndHoldEnabled = false` to the global domain so held
    /// keys repeat instead of showing the accent picker. NOTE: this has NO
    /// live-HID equivalent — it only affects apps launched after the change.
    func disablePressAndHold()
    /// Deletes `ApplePressAndHoldEnabled` (nil write) so the system default
    /// (accent picker) returns, consistent with the delete-keys restore semantics.
    func restorePressAndHold()
}

/// Writes `InitialKeyRepeat` / `KeyRepeat` to the global domain via CFPreferences —
/// the API equivalent of `defaults write -g` (kCFPreferencesCurrentUser + AnyHost
/// targets ~/Library/Preferences/.GlobalPreferences.plist). No shelling out, so no
/// PATH/argument injection surface (T-czd-03).
struct CFGlobalKeyRepeatApplier: GlobalKeyRepeatApplying, Sendable {

    func apply(initialKeyRepeat: Int, keyRepeat: Int) {
        CFPreferencesSetValue("InitialKeyRepeat" as CFString,
                              initialKeyRepeat as CFNumber,
                              kCFPreferencesAnyApplication,
                              kCFPreferencesCurrentUser,
                              kCFPreferencesAnyHost)
        CFPreferencesSetValue("KeyRepeat" as CFString,
                              keyRepeat as CFNumber,
                              kCFPreferencesAnyApplication,
                              kCFPreferencesCurrentUser,
                              kCFPreferencesAnyHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication,
                                 kCFPreferencesCurrentUser,
                                 kCFPreferencesAnyHost)
    }

    /// Deletes both keys (nil value) — the honest restore: the system default
    /// behavior applies again, exactly as if the user had never customized them.
    func restoreSystemDefaults() {
        CFPreferencesSetValue("InitialKeyRepeat" as CFString,
                              nil,
                              kCFPreferencesAnyApplication,
                              kCFPreferencesCurrentUser,
                              kCFPreferencesAnyHost)
        CFPreferencesSetValue("KeyRepeat" as CFString,
                              nil,
                              kCFPreferencesAnyApplication,
                              kCFPreferencesCurrentUser,
                              kCFPreferencesAnyHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication,
                                 kCFPreferencesCurrentUser,
                                 kCFPreferencesAnyHost)
    }

    /// Applies session-live HID parameters via `/usr/bin/hidutil property --set`.
    /// Fixed absolute path prevents PATH hijacking (T-ds6-01, Phase 08 pattern).
    /// The property dict is built from `[String: Int]` and serialized with
    /// JSONSerialization — values are clamped tick-derived integers, so there is
    /// no injection surface (T-ds6-02).
    func applyLiveHID(initialKeyRepeatNs: Int, keyRepeatNs: Int) {
        let properties: [String: Int] = [
            "HIDInitialKeyRepeat": initialKeyRepeatNs,
            "HIDKeyRepeat": keyRepeatNs
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: properties),
              let json = String(data: data, encoding: .utf8) else {
            print("KeyRepeat: failed to serialize hidutil property dict")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = ["property", "--set", json]
        do {
            try process.run()
            // hidutil returns near-instantly; fire-and-forget keeps the main
            // thread responsive during slider drags.
        } catch {
            print("KeyRepeat: failed to run hidutil — \(error)")
        }
    }

    /// Writes `ApplePressAndHoldEnabled = false` to the global domain via
    /// CFPreferences — no shelling out, so no PATH/argument injection surface
    /// (T-ezk-01, same rationale as T-czd-03). There is NO live-HID equivalent:
    /// only apps launched after this change pick it up.
    func disablePressAndHold() {
        CFPreferencesSetValue("ApplePressAndHoldEnabled" as CFString,
                              kCFBooleanFalse,
                              kCFPreferencesAnyApplication,
                              kCFPreferencesCurrentUser,
                              kCFPreferencesAnyHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication,
                                 kCFPreferencesCurrentUser,
                                 kCFPreferencesAnyHost)
    }

    /// Deletes `ApplePressAndHoldEnabled` (nil value) — the honest restore: the
    /// system default (accent picker) applies again for newly launched apps, so
    /// the user is never left with a stuck-disabled accent picker (T-ezk-02).
    func restorePressAndHold() {
        CFPreferencesSetValue("ApplePressAndHoldEnabled" as CFString,
                              nil,
                              kCFPreferencesAnyApplication,
                              kCFPreferencesCurrentUser,
                              kCFPreferencesAnyHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication,
                                 kCFPreferencesCurrentUser,
                                 kCFPreferencesAnyHost)
    }
}

// MARK: - KeyRepeatModule

/// Controls macOS keyboard repeat delay (`InitialKeyRepeat`) and repeat rate
/// (`KeyRepeat`), including values below the System Settings minimums
/// (InitialKeyRepeat < 15, KeyRepeat < 2). Values are in system ticks of
/// 1/60 s (~16.7 ms) each — NOT 15 ms.
///
/// Effect timing: every apply writes both the global defaults (persistence
/// across login) AND the session-live HID parameters via `applyLiveHID`, so
/// changes take effect immediately in all running apps.
///
/// Press-and-hold: every apply also disables the macOS accent popup
/// (`ApplePressAndHoldEnabled = false`) so held keys repeat cleanly; disable/
/// restore deletes the key so the accent picker returns. Unlike the repeat
/// speeds, this has NO live-HID equivalent — it only affects apps launched
/// after the change (running apps keep their behavior until relaunch).
@Observable
final class KeyRepeatModule: FeatureModule {
    let id = "key-repeat"
    var name: String { String(localized: "module.key_repeat.name") }
    var moduleDescription: String { String(localized: "module.key_repeat.description") }
    let icon = "keyboard"
    let isAvailable = true

    /// Allowed ranges — clamping floor prevents pathological 0 values (T-czd-02).
    /// Initial delay is truncated to the fast tail: 10 steps (5...14 ticks,
    /// 83–233 ms) at 1/60 s per tick — slower-than-System-Settings delays are
    /// intentionally unselectable. Repeat rate spans 10 steps (1...10 ticks,
    /// 17–167 ms), extending past the System Settings fast tail and including
    /// the macOS default (6 ticks).
    static let initialKeyRepeatRange = 5...14
    static let keyRepeatRange = 1...10

    /// macOS default tick values (System Settings midpoints).
    /// `macOSDefaultInitialKeyRepeatTicks` (25) is NOT a valid slider position
    /// (outside 5...14); `macOSDefaultKeyRepeatTicks` (6) IS a valid slider
    /// position within 1...10 and is used as the restore landing value for the
    /// repeat-rate slider. Both also derive the live-HID restore constants below.
    static let macOSDefaultInitialKeyRepeatTicks = 25
    static let macOSDefaultKeyRepeatTicks = 6

    /// macOS default live HID values (ns): 25 and 6 ticks at 1/60 s each.
    static let macOSDefaultInitialKeyRepeatNs = nanoseconds(forTicks: macOSDefaultInitialKeyRepeatTicks)
    static let macOSDefaultKeyRepeatNs = nanoseconds(forTicks: macOSDefaultKeyRepeatTicks)

    /// Converts system ticks (1/60 s each) to nanoseconds for the HID event system.
    static func nanoseconds(forTicks ticks: Int) -> Int {
        Int((Double(ticks) * 1_000_000_000.0 / 60.0).rounded())
    }

    /// Converts system ticks (1/60 s each) to milliseconds for display.
    static func milliseconds(forTicks ticks: Int) -> Int {
        Int((Double(ticks) * 1000.0 / 60.0).rounded())
    }

    private static let enabledKey = "com.macssential.module.key-repeat.enabled"
    private static let initialKeyRepeatKey = "com.macssential.module.key-repeat.initialKeyRepeat"
    private static let keyRepeatKey = "com.macssential.module.key-repeat.keyRepeat"

    private let applier: GlobalKeyRepeatApplying
    private let defaults: UserDefaults

    var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled { activate() } else { deactivate() }
        }
    }

    // Backing storage is written directly by restoreMacOSDefaults() so the restore
    // never re-applies values (deleting the global keys IS the restore).
    private var storedInitialKeyRepeat: Int
    private var storedKeyRepeat: Int

    /// Delay until key repeat starts, in 1/60 s (~16.7 ms) ticks (default 14 = range maximum, 233 ms).
    var initialKeyRepeat: Int {
        get { storedInitialKeyRepeat }
        set {
            storedInitialKeyRepeat = Self.clamp(newValue, to: Self.initialKeyRepeatRange)
            defaults.set(storedInitialKeyRepeat, forKey: Self.initialKeyRepeatKey)
            if isEnabled { applyCurrentValues() }
        }
    }

    /// Interval between repeats, in 1/60 s (~16.7 ms) ticks (default 2 = System Settings fastest).
    var keyRepeat: Int {
        get { storedKeyRepeat }
        set {
            storedKeyRepeat = Self.clamp(newValue, to: Self.keyRepeatRange)
            defaults.set(storedKeyRepeat, forKey: Self.keyRepeatKey)
            if isEnabled { applyCurrentValues() }
        }
    }

    init(applier: GlobalKeyRepeatApplying = CFGlobalKeyRepeatApplier(),
         defaults: UserDefaults = .standard) {
        self.applier = applier
        self.defaults = defaults
        self.isEnabled = defaults.bool(forKey: Self.enabledKey)
        let storedInitial = defaults.object(forKey: Self.initialKeyRepeatKey) as? Int
            ?? Self.initialKeyRepeatRange.upperBound
        let storedRepeat = defaults.object(forKey: Self.keyRepeatKey) as? Int ?? 2
        self.storedInitialKeyRepeat = Self.clamp(storedInitial, to: Self.initialKeyRepeatRange)
        self.storedKeyRepeat = Self.clamp(storedRepeat, to: Self.keyRepeatRange)
    }

    @MainActor var settingsView: AnyView? {
        AnyView(KeyRepeatSettingsView(module: self))
    }

    func activate() {
        applyCurrentValues()
    }

    /// Turning the module off returns macOS to default behavior: deletes the
    /// defaults keys (persistence) and resets live HID (immediate revert).
    func deactivate() {
        applier.restoreSystemDefaults()
        applier.restorePressAndHold()
        restoreLiveHIDToMacOSDefaults()
    }

    /// Deletes the global keys (the deletion IS the restore) and reverts live HID
    /// to the true macOS defaults. The initial-delay slider lands on the range
    /// maximum (14) because the true default (25 ticks) is out of range; the
    /// repeat-rate slider lands on the true macOS default (6 ticks, now in range),
    /// consistent with the live-HID revert.
    /// Writes backing storage directly so the didSet-style apply is skipped —
    /// after a restore no custom values may remain in the global domain.
    func restoreMacOSDefaults() {
        storedInitialKeyRepeat = Self.initialKeyRepeatRange.upperBound
        storedKeyRepeat = Self.macOSDefaultKeyRepeatTicks
        defaults.set(storedInitialKeyRepeat, forKey: Self.initialKeyRepeatKey)
        defaults.set(storedKeyRepeat, forKey: Self.keyRepeatKey)
        applier.restoreSystemDefaults()
        applier.restorePressAndHold()
        restoreLiveHIDToMacOSDefaults()
    }

    // MARK: - Private

    private func applyCurrentValues() {
        applier.apply(initialKeyRepeat: storedInitialKeyRepeat, keyRepeat: storedKeyRepeat)
        applier.applyLiveHID(initialKeyRepeatNs: Self.nanoseconds(forTicks: storedInitialKeyRepeat),
                             keyRepeatNs: Self.nanoseconds(forTicks: storedKeyRepeat))
        applier.disablePressAndHold()
    }

    /// Resets the session-live HID parameters to the macOS defaults so a
    /// deactivate/restore takes effect immediately, not only after re-login.
    private func restoreLiveHIDToMacOSDefaults() {
        applier.applyLiveHID(initialKeyRepeatNs: Self.macOSDefaultInitialKeyRepeatNs,
                             keyRepeatNs: Self.macOSDefaultKeyRepeatNs)
    }

    private static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
