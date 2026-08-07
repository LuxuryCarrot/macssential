import SwiftUI

// MARK: - Dock Recent Apps System Controller

/// Abstracts reads/writes of the `com.apple.dock show-recents` system setting so
/// tests can inject a mock and never touch the real Dock (no killall flashes).
/// Semantics: module enabled == recents HIDDEN == show-recents false.
protocol DockRecentAppsSystemControlling {
    func isSystemRecentsShown() -> Bool
    func setSystemRecentsShown(_ shown: Bool)
}

/// Real implementation: reads via CFPreferences (no shelling out), writes via
/// the existing absolute-path Process pattern (`defaults write` + `killall Dock`).
struct DockRecentAppsSystemController: DockRecentAppsSystemControlling, Sendable {

    /// Reads the current `com.apple.dock show-recents` value. Synchronizes first
    /// so cached values from external changes (System Settings) are picked up.
    /// Missing key means the macOS default: recents shown.
    func isSystemRecentsShown() -> Bool {
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        guard let value = CFPreferencesCopyAppValue("show-recents" as CFString,
                                                    "com.apple.dock" as CFString) else {
            return true
        }
        return (value as? Bool) ?? true
    }

    /// Writes the show-recents value and restarts the Dock so it takes effect.
    /// Absolute executable paths prevent PATH hijacking (Phase 08 pattern);
    /// arguments are compile-time constants — no injection surface.
    func setSystemRecentsShown(_ shown: Bool) {
        runProcess("/usr/bin/defaults", ["write", "com.apple.dock", "show-recents", "-bool", shown ? "true" : "false"])
        runProcess("/usr/bin/killall", ["Dock"])
    }

    private func runProcess(_ path: String, _ args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            print("[macssential] Process failed (\(path) \(args)): \(error)")
        }
    }
}

// MARK: - DockRecentAppsModule

@Observable
final class DockRecentAppsModule: FeatureModule, SystemStateSyncing {
    let id = "dock-recent-apps"
    var name: String { String(localized: "module.dock_recent_apps.name") }
    var moduleDescription: String { String(localized: "module.dock_recent_apps.description") }
    let icon = "clock.arrow.circlepath"
    let isAvailable = true

    private let system: DockRecentAppsSystemControlling

    /// When true, the didSet skips activate()/deactivate() — used by
    /// syncFromSystem() so adopting external state never restarts the Dock.
    private var suppressSideEffects = false

    var isEnabled: Bool {
        didSet {
            // The app key mirrors the flag; the system remains the source of truth.
            UserDefaults.standard.set(isEnabled, forKey: "com.macssential.module.dock-recent-apps.enabled")
            guard !suppressSideEffects else { return }
            if isEnabled { activate() } else { deactivate() }
        }
    }

    init(system: DockRecentAppsSystemControlling = DockRecentAppsSystemController()) {
        self.system = system
        // System state is the source of truth — a stale app flag must never
        // shadow reality. Enabled means recents are hidden.
        self.isEnabled = !system.isSystemRecentsShown()
    }

    /// Re-reads the real system show-recents state and adopts it without firing
    /// any writes or Dock restarts.
    func syncFromSystem() {
        let systemValue = !system.isSystemRecentsShown()
        guard systemValue != isEnabled else { return }
        suppressSideEffects = true
        defer { suppressSideEffects = false }
        isEnabled = systemValue
    }

    func activate() {
        // Idempotent: already-hidden recents never trigger a Dock restart flash.
        guard system.isSystemRecentsShown() else { return }
        system.setSystemRecentsShown(false)
    }

    func deactivate() {
        // Idempotent: already-shown recents never trigger a Dock restart flash.
        guard !system.isSystemRecentsShown() else { return }
        system.setSystemRecentsShown(true)
    }
}
