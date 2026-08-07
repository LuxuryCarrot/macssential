import Foundation
import ObjectiveC.runtime

// MARK: - LocalizedBundle

/// Bundle subclass that redirects localization lookups to the language-specific `.lproj`
/// bundle stored as an associated object on `Bundle.main`.
///
/// Installed once via `object_setClass` in `BundleLocaleSwizzle.enforce`. After the class
/// swap, all localization calls — both `String(localized:)` (Swift 6, which calls the
/// private `_localizedStringForKey:value:table:localizations:`) and `NSLocalizedString`
/// (which calls the public `localizedString(forKey:value:table:)`) — are intercepted and
/// redirected to the active language bundle.
final class LocalizedBundle: Bundle, @unchecked Sendable {

    /// Intercepts `String(localized:)` in Swift 6.
    ///
    /// Swift 6's `String.init(localized:)` bypasses the public ObjC
    /// `localizedString(forKey:value:table:)` and calls this private variant instead.
    /// Overriding it (via `@objc` with the exact ObjC selector) is the only way to
    /// intercept `String(localized:)` at runtime without modifying call sites.
    @objc func _localizedStringForKey(
        _ key: String,
        value: String?,
        table tableName: String?,
        localizations: AnyObject?
    ) -> String {
        if let langBundle = objc_getAssociatedObject(Bundle.main, &AssociatedKeys.bundle) as? Bundle {
            return langBundle.localizedString(forKey: key, value: value, table: tableName)
        }
        // Fallback: call the superclass implementation (system language resolution)
        return super.localizedString(forKey: key, value: value, table: tableName)
    }

    /// Intercepts `NSLocalizedString` and direct `bundle.localizedString(forKey:)` calls.
    override func localizedString(forKey key: String,
                                  value: String?,
                                  table tableName: String?) -> String {
        if let langBundle = objc_getAssociatedObject(Bundle.main, &AssociatedKeys.bundle) as? Bundle {
            return langBundle.localizedString(forKey: key, value: value, table: tableName)
        }
        return super.localizedString(forKey: key, value: value, table: tableName)
    }
}

// MARK: - AssociatedKeys

private enum AssociatedKeys {
    /// Key used to store the active language bundle as an associated object on `Bundle.main`.
    /// Marked `nonisolated(unsafe)` because it is used as an ObjC associated-object key
    /// (its address is the key) from a `nonisolated` context. The value is a string constant
    /// that is never mutated after initialisation.
    nonisolated(unsafe) static var bundle = "com.macssential.localizedBundle"
}

// MARK: - BundleLocaleSwizzle

/// One-shot bundle class swizzle. After `enforce` is called:
/// - `Bundle.main`'s class is `LocalizedBundle` (swapped exactly once).
/// - The active `.lproj` bundle is stored as an associated object and updated on each
///   subsequent `enforce` call without re-swapping the class (Pitfall 3 mitigation).
enum BundleLocaleSwizzle {
    /// Guards `object_setClass` so it runs at most once per process lifetime. Marked
    /// `nonisolated(unsafe)` because it is mutated from a `nonisolated` context — the
    /// ObjC runtime call cannot be actor-isolated. Write access is effectively serialised
    /// because `enforce` is only called from `@MainActor` methods (or at init time on the
    /// main actor). No concurrent writers exist in this codebase.
    nonisolated(unsafe) private static var swizzled: Bool = false

    /// Set `Bundle.main` to serve strings from the `.lproj` for `languageCode`.
    ///
    /// - Falls back to `"en"` if the requested `.lproj` path cannot be found.
    /// - Falls back to `Bundle.main.bundlePath` if even `"en"` is missing (Assumption A3).
    /// - Returns silently without changing state if the resolved path cannot produce a Bundle.
    nonisolated static func enforce(_ languageCode: String) {
        let mainBundle = Bundle.main

        // 1. Resolve path: requested language → "en" → bare bundle root (defensive)
        let path: String
        if let p = mainBundle.path(forResource: languageCode, ofType: "lproj") {
            path = p
        } else if let p = mainBundle.path(forResource: "en", ofType: "lproj") {
            path = p
        } else {
            path = mainBundle.bundlePath
        }

        // 2. Construct the language bundle — defensive nil check (Pitfall 4)
        guard let langBundle = Bundle(path: path) else { return }

        // 3. Store as associated object (updates language without re-swapping class)
        objc_setAssociatedObject(
            mainBundle,
            &AssociatedKeys.bundle,
            langBundle,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )

        // 4. Swap Bundle.main's class exactly once (Pitfall 3)
        if !swizzled {
            object_setClass(mainBundle, LocalizedBundle.self)
            swizzled = true
        }
    }
}

// MARK: - LocalizationService

/// Runtime-switchable localization backbone for the macssential app.
///
/// Responsibilities:
/// - Reads persisted language preference from UserDefaults on init.
/// - Falls back to the system language, then English, when no preference is stored.
/// - Applies `BundleLocaleSwizzle` so all `String(localized:)` and `NSLocalizedString`
///   calls return strings in the selected language without an app restart.
/// - Publishes `currentLanguage` so SwiftUI views that reference it re-render after
///   `setLanguage(_:)`.
///
/// Usage: Instantiate once in `AppDelegate` and inject via `.environment(localizationService)`.
/// Do NOT use a `static let shared` singleton — follow the instance pattern established by
/// `AccessibilityPermissionManager` (see RESEARCH.md Open Question #2).
@Observable
@MainActor
final class LocalizationService {

    /// UserDefaults key for persisting the selected language code.
    static let languageKey = "com.macssential.language"

    /// Currently active display language. Observing views re-render when this changes.
    private(set) var currentLanguage: AppLanguage

    /// Designated initialiser. Reads persisted preference; falls back to system language
    /// then `.english`. Applies the bundle swizzle before returning so the first view
    /// render already uses the correct `.lproj`.
    init() {
        let saved = UserDefaults.standard.string(forKey: Self.languageKey)
        let resolved = saved
            ?? AppLanguage.matchingSystemLanguage()
            ?? AppLanguage.english.rawValue
        let lang = AppLanguage(rawValue: resolved) ?? .english
        currentLanguage = lang
        // BundleLocaleSwizzle.enforce is nonisolated — callable directly from @MainActor init
        BundleLocaleSwizzle.enforce(lang.rawValue)
    }

    /// Switch the active language, persist the choice, and update the bundle swizzle.
    ///
    /// Always persists the choice to UserDefaults regardless of whether the language changed,
    /// ensuring UserDefaults reflects an explicit user choice even when the selected language
    /// matches the auto-detected system locale.
    func setLanguage(_ language: AppLanguage) {
        // Always persist — covers the case where system locale matches the selected language
        // and the guard below would otherwise skip the UserDefaults write.
        UserDefaults.standard.set(language.rawValue, forKey: Self.languageKey)

        // Guard expensive operations: currentLanguage assignment triggers @Observable re-render,
        // and enforce() updates the associated object on Bundle.main.
        guard language != currentLanguage else { return }
        currentLanguage = language  // @Observable trigger — invalidates dependent views
        BundleLocaleSwizzle.enforce(language.rawValue)
    }
}
