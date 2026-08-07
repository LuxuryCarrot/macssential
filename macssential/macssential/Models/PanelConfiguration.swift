import Foundation

/// UserDefaults-backed store deciding which modules appear as "quick slots" in the
/// menu-bar panel. Panel visibility is fully independent from a module's enabled state —
/// hiding a module from the panel never disables it.
///
/// Default (no stored value): all modules are visible EXCEPT:
/// - `korean-filename-normalizer`, which is visible by default only when the app language
///   is affected by the NFD filename issue (see `AppLanguage.hasNFDFilenameIssue`).
/// - `scroll-direction`, which was relocated to Settings (Phase 13) and is hidden by default
///   in every locale. Users can still add it back via Settings → Panel Layout.
///
/// Once the user customizes visibility (any stored value exists), the stored choice wins
/// over the default for every module.
@Observable
@MainActor
final class PanelConfiguration {
    static let storageKey = "com.macssential.panel.visibleModules"

    /// Modules that are hidden from the panel by default regardless of locale.
    private static let alwaysDefaultHidden: Set<String> = ["scroll-direction"]

    /// Pure, unit-testable default computation. No UserDefaults access.
    /// Returns all `allModuleIDs` minus the always-hidden set, and minus
    /// `korean-filename-normalizer` unless the app language suffers the NFD
    /// filename issue or `systemAffectedByNFD` reports that one of the user's
    /// preferred system languages does.
    static func defaultVisibleIDs(
        allModuleIDs: [String],
        language: AppLanguage,
        systemAffectedByNFD: Bool = false
    ) -> Set<String> {
        var visible = Set(allModuleIDs).subtracting(alwaysDefaultHidden)
        if !language.hasNFDFilenameIssue && !systemAffectedByNFD {
            visible.remove("korean-filename-normalizer")
        }
        return visible
    }

    private(set) var visibleModuleIDs: Set<String>
    private let defaults: UserDefaults

    init(
        allModuleIDs: [String],
        language: AppLanguage,
        systemAffectedByNFD: Bool = false,
        defaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
        if let stored = defaults.stringArray(forKey: Self.storageKey) {
            // Stored value wins over the default once the user has customized.
            self.visibleModuleIDs = Set(stored)
        } else {
            self.visibleModuleIDs = Self.defaultVisibleIDs(
                allModuleIDs: allModuleIDs,
                language: language,
                systemAffectedByNFD: systemAffectedByNFD
            )
        }
    }

    func isVisible(_ id: String) -> Bool {
        visibleModuleIDs.contains(id)
    }

    func setVisible(_ id: String, _ visible: Bool) {
        if visible {
            visibleModuleIDs.insert(id)
        } else {
            visibleModuleIDs.remove(id)
        }
        defaults.set(Array(visibleModuleIDs), forKey: Self.storageKey)
    }
}
