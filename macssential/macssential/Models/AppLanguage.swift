import Foundation

/// Supported display languages for the macssential app.
///
/// Raw values are BCP 47 language codes used in `.lproj` bundle lookup and UserDefaults storage.
/// Display names use native scripts (Pitfall 6 mitigation) — they are never passed through
/// `String(localized:)` so the picker remains readable after switching to an unfamiliar language.
enum AppLanguage: String, CaseIterable, Identifiable {
    case english    = "en"
    case korean     = "ko"
    case japanese   = "ja"
    case chineseSimplified = "zh-Hans"
    case spanish    = "es"
    case french     = "fr"
    case german     = "de"
    case portuguese = "pt"
    case italian    = "it"
    case russian    = "ru"
    case vietnamese = "vi"

    /// Stable identifier equal to the BCP 47 raw value.
    var id: String { rawValue }

    /// Human-readable name in the language's own script.
    /// These are fixed constants — never localized — per Pitfall 6.
    var displayName: String {
        switch self {
        case .english:    return "English"
        case .korean:     return "한국어"
        case .japanese:   return "日本語"
        case .chineseSimplified: return "中文（简体）"
        case .spanish:    return "Español"
        case .french:     return "Français"
        case .german:     return "Deutsch"
        case .portuguese: return "Português"
        case .italian:    return "Italiano"
        case .russian:    return "Русский"
        case .vietnamese: return "Tiếng Việt"
        }
    }

    /// Whether filenames in this language's script are visibly corrupted by APFS/HFS+
    /// NFD decomposition when exchanged with NFC-based systems (Windows, web).
    /// Korean: Hangul syllables decompose into jamo (가 → ㄱ+ㅏ).
    /// Japanese: dakuten/handakuten split off as combining marks (が → か+U+3099).
    /// Latin/Cyrillic diacritic orthographies decompose into combining marks.
    /// English (ASCII) and Chinese (no decomposable everyday characters) are unaffected.
    var hasNFDFilenameIssue: Bool {
        NFDFilenameIssue.affectedLanguageCodes.contains(String(rawValue.prefix(2)))
    }

    /// Returns the first BCP 47 prefix from `Locale.preferredLanguages` that matches a
    /// supported language code ("en", "ko", or "ja"), or `nil` if none match.
    ///
    /// The caller is responsible for providing a fallback; returning `nil` allows
    /// `LocalizationService.init` to distinguish "no system match" from "English preferred".
    static func matchingSystemLanguage() -> String? {
        for lang in Locale.preferredLanguages {
            // Longest-prefix match first so "zh-Hans-CN" resolves to "zh-Hans"
            // before the two-letter fallback would miss it.
            if let match = AppLanguage.allCases.first(where: {
                lang == $0.rawValue || lang.hasPrefix($0.rawValue + "-")
            }) {
                return match.rawValue
            }
            let code = String(lang.prefix(2))
            if AppLanguage(rawValue: code) != nil {
                return code
            }
        }
        return nil
    }
}

/// Central knowledge about the APFS/HFS+ NFD filename decomposition issue.
///
/// The issue affects every language whose script uses precomposed characters that
/// Unicode NFD splits apart: Hangul syllables (가 → ㄱ+ㅏ), kana with dakuten
/// (が → か+U+3099), and Latin/Greek/Cyrillic letters with diacritics
/// (é → e+U+0301, ό → ο+U+0301, й → и+U+0306). The app UI only ships in
/// EN/KO/JA, so affected users of other languages are detected via the system's
/// preferred-language list rather than the app display language.
enum NFDFilenameIssue {
    /// ISO 639-1 codes of languages whose everyday orthography contains characters
    /// that NFD visibly decomposes in filenames.
    static let affectedLanguageCodes: Set<String> = [
        // Hangul / kana
        "ko", "ja",
        // Vietnamese — heaviest Latin-diacritic orthography
        "vi",
        // Latin scripts with diacritics (Western/Central/Northern European, Turkic)
        "fr", "de", "es", "pt", "it", "ca", "nl",
        "cs", "sk", "pl", "hu", "ro", "hr", "sl", "sr", "bs",
        "sv", "da", "nb", "nn", "no", "fi", "is", "et", "lv", "lt",
        "tr", "az",
        // Greek — tonos/dialytika decompose
        "el",
        // Cyrillic with breve/diaeresis (й, ё, ў, ѐ)
        "ru", "uk", "be", "bg", "mk",
    ]

    /// True when any of the user's preferred languages is affected.
    /// `preferred` is injectable for tests; defaults to the live system list.
    static func affectsSystemLanguages(
        _ preferred: [String] = Locale.preferredLanguages
    ) -> Bool {
        preferred.contains { affectedLanguageCodes.contains(String($0.prefix(2))) }
    }
}
