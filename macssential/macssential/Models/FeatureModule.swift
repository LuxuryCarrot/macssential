import SwiftUI

protocol FeatureModule: AnyObject, Identifiable {
    var id: String { get }
    var name: String { get }
    var icon: String { get }
    var isEnabled: Bool { get set }
    var isAvailable: Bool { get }

    func activate()
    func deactivate()

    /// Called at app quit and on Accessibility permission revocation. Release
    /// ONLY live runtime resources (CGEventTaps, FSEvents streams). Must NOT
    /// revert persistent system preferences — users expect those to survive app
    /// quit. `deactivate()` remains the explicit user toggle-OFF path and still
    /// reverts preferences.
    func releaseResources()

    var moduleDescription: String { get }

    @MainActor var settingsView: AnyView? { get }

    var requiresAccessibilityPermission: Bool { get }

    /// True when this module should be shown to a user running the app in `language`.
    /// Protocol requirement (not just an extension member) so conforming modules can
    /// provide their own logic with dynamic dispatch — e.g. the NFD filename
    /// normalizer also consults the system's preferred languages.
    func isRelevant(to language: AppLanguage) -> Bool
}

extension FeatureModule {
    var moduleDescription: String { "" }
    @MainActor var settingsView: AnyView? { nil }
    var requiresAccessibilityPermission: Bool { false }

    /// Default: preference modules hold no live runtime resources — nothing to release.
    func releaseResources() {}

    /// Default: modules are relevant to every language.
    func isRelevant(to language: AppLanguage) -> Bool { true }
}
