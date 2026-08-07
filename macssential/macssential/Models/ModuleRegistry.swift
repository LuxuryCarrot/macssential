import Foundation

@Observable
final class ModuleRegistry {
    let modules: [any FeatureModule]

    init(modules: [any FeatureModule]) {
        self.modules = modules
    }

    convenience init() {
        // One-shot migration (CLN-01): restore mouse scaling default for users upgrading from v1.0
        if !UserDefaults.standard.bool(forKey: "com.macssential.v11.mouse-scaling-restored") {
            Self.runMigrationProcess("/usr/bin/defaults", ["write", "-g", "com.apple.mouse.scaling", "-integer", "3"])
            UserDefaults.standard.set(true, forKey: "com.macssential.v11.mouse-scaling-restored")
        }
        var modules: [any FeatureModule] = [
            DockAnchorModule(),
            DockAutoHideModule(),
            DockRecentAppsModule(),
            HiddenFilesModule(),
        ]
#if DEBUG
        modules.append(FinderSortModule()) // QUICK-KVJ-01: Finder default arrange-by (Debug-only per QUICK-KBR-02)
#endif
        modules.append(contentsOf: [
            KeyRepeatModule(), // QUICK-CZD-01: key repeat delay control
            ScrollDirectionModule(),
            ScreenshotAutoCopyModule(),   // SCRN-01: registers module so panel renders toggle
            KoreanFilenameNormalizerModule(), // KFN-01: registers module so panel renders toggle
        ] as [any FeatureModule])
        self.init(modules: modules)
    }

    func activateEnabledModules() {
        for module in modules where module.isEnabled && module.isAvailable {
            module.activate()
        }
    }

    /// Releases live runtime resources (CGEventTaps, FSEvents streams) for ALL
    /// modules regardless of isEnabled — releasing an already-stopped tap is
    /// safe and idempotent, while gating on isEnabled could leak a tap whose
    /// flag was flipped without deactivation. Never reverts system preferences;
    /// call at app quit and on Accessibility permission revocation.
    func releaseAllRuntimeResources() {
        for module in modules {
            module.releaseResources()
        }
    }

    /// Mutually exclusive module groups. Enabling one disables the other.
    private static let exclusiveGroups: [[String]] = [
        ["dock-anchor", "dock-autohide"],
    ]

    /// Call after a module is enabled to disable conflicting modules in the same exclusive group.
    func disableConflicting(with moduleId: String) {
        for group in Self.exclusiveGroups where group.contains(moduleId) {
            for conflictId in group where conflictId != moduleId {
                if let conflicting = modules.first(where: { $0.id == conflictId }) {
                    // Re-sync with reality first: a stale flag (e.g. system autohide
                    // toggled externally) must not make the disable a no-op.
                    (conflicting as? SystemStateSyncing)?.syncFromSystem()
                    if conflicting.isEnabled {
                        conflicting.isEnabled = false
                    }
                }
            }
        }
    }

    /// Re-syncs every SystemStateSyncing module with the real system state.
    /// Fires no system writes — call on panel open so toggles show truth.
    func syncModulesFromSystem() {
        for module in modules {
            (module as? SystemStateSyncing)?.syncFromSystem()
        }
    }

    // MARK: - Migration Helper

    private static func runMigrationProcess(_ path: String, _ args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            print("[macssential] Migration process failed (\(path) \(args)): \(error)")
        }
    }
}
