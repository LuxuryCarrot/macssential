import SwiftUI

// MARK: - System State Syncing

/// Modules whose enabled state mirrors a real system setting that can change
/// outside the app (System Settings, keyboard shortcuts). `syncFromSystem()`
/// re-reads reality and updates the module flag WITHOUT firing side effects.
protocol SystemStateSyncing {
    func syncFromSystem()
}

// MARK: - Dock AutoHide System Controller

/// Abstracts reads/writes of the `com.apple.dock autohide` system setting so
/// tests can inject a mock and never touch the real Dock (no killall flashes).
protocol DockAutoHideSystemControlling {
    func isSystemAutoHideOn() -> Bool
    func setSystemAutoHide(_ on: Bool)
}

/// Real implementation: reads via CFPreferences (no shelling out), writes via
/// the existing absolute-path Process pattern (`defaults write` + `killall Dock`).
struct DockAutoHideSystemController: DockAutoHideSystemControlling, Sendable {

    /// Reads the current `com.apple.dock autohide` value. Synchronizes first so
    /// cached values from external changes (Cmd+Opt+D, System Settings) are
    /// picked up. Missing key means the macOS default: autohide off.
    func isSystemAutoHideOn() -> Bool {
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        guard let value = CFPreferencesCopyAppValue("autohide" as CFString,
                                                    "com.apple.dock" as CFString) else {
            return false
        }
        return (value as? Bool) ?? false
    }

    /// Writes the autohide value and restarts the Dock so it takes effect.
    /// Absolute executable paths prevent PATH hijacking (Phase 08 pattern);
    /// arguments are compile-time constants — no injection surface.
    func setSystemAutoHide(_ on: Bool) {
        runProcess("/usr/bin/defaults", ["write", "com.apple.dock", "autohide", "-bool", on ? "true" : "false"])
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

// MARK: - DockAutoHideModule

@Observable
final class DockAutoHideModule: FeatureModule, SystemStateSyncing {
    let id = "dock-autohide"
    var name: String { String(localized: "module.dock_autohide.name") }
    var moduleDescription: String { String(localized: "module.dock_autohide.description") }
    let icon = "dock.arrow.down.rectangle"
    let isAvailable = true

    private let system: DockAutoHideSystemControlling

    /// When true, the didSet skips activate()/deactivate() — used by
    /// syncFromSystem() so adopting external state never restarts the Dock.
    private var suppressSideEffects = false

    var isEnabled: Bool {
        didSet {
            // The app key mirrors the flag; the system remains the source of truth.
            UserDefaults.standard.set(isEnabled, forKey: "com.macssential.module.dock-autohide.enabled")
            guard !suppressSideEffects else { return }
            if isEnabled { activate() } else { deactivate() }
        }
    }

    init(system: DockAutoHideSystemControlling = DockAutoHideSystemController()) {
        self.system = system
        // System state is the source of truth — a stale app flag must never
        // shadow reality (fixes the dock-anchor conflict-resolution no-op).
        self.isEnabled = system.isSystemAutoHideOn()
    }

    /// Re-reads the real system autohide state and adopts it without firing
    /// any writes or Dock restarts.
    func syncFromSystem() {
        let systemValue = system.isSystemAutoHideOn()
        guard systemValue != isEnabled else { return }
        suppressSideEffects = true
        defer { suppressSideEffects = false }
        isEnabled = systemValue
    }

    func activate() {
        // Idempotent: an already-hidden Dock never gets a restart flash.
        guard !system.isSystemAutoHideOn() else { return }
        system.setSystemAutoHide(true)
    }

    func deactivate() {
        // Idempotent: an already-visible Dock never gets a restart flash.
        guard system.isSystemAutoHideOn() else { return }
        system.setSystemAutoHide(false)
    }
}
