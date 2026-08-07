import XCTest
@testable import macssential

final class AppLanguageTests: XCTestCase {

    // MARK: - Enum shape

    func testAllCasesHasExactlyElevenCases() {
        XCTAssertEqual(AppLanguage.allCases.count, 11,
                        "AppLanguage should have exactly 11 cases")
        for lang: AppLanguage in [.english, .korean, .japanese, .chineseSimplified,
                                  .spanish, .french, .german, .portuguese,
                                  .italian, .russian, .vietnamese] {
            XCTAssertTrue(AppLanguage.allCases.contains(lang),
                          "AppLanguage.allCases should contain .\(lang)")
        }
    }

    func testEveryLanguageHasLprojResource() {
        // Each case must have a matching .lproj with Localizable.strings in the app bundle,
        // otherwise BundleLocaleSwizzle silently falls back to English.
        let bundle = Bundle(for: LocalizedBundle.self)
        for lang in AppLanguage.allCases {
            XCTAssertNotNil(bundle.path(forResource: lang.rawValue, ofType: "lproj"),
                            "Missing \(lang.rawValue).lproj resource for AppLanguage.\(lang)")
        }
    }

    // MARK: - Raw values are BCP 47 language codes

    func testRawValuesAreLanguageCodes() {
        XCTAssertEqual(AppLanguage.english.rawValue, "en")
        XCTAssertEqual(AppLanguage.korean.rawValue, "ko")
        XCTAssertEqual(AppLanguage.japanese.rawValue, "ja")
        XCTAssertEqual(AppLanguage.chineseSimplified.rawValue, "zh-Hans")
        XCTAssertEqual(AppLanguage.vietnamese.rawValue, "vi")
    }

    // MARK: - RawRepresentable round-trip

    func testRawRepresentableRoundTrip() {
        for lang in AppLanguage.allCases {
            let raw = lang.rawValue
            let restored = AppLanguage(rawValue: raw)
            XCTAssertEqual(restored, lang,
                            "AppLanguage should round-trip through rawValue")
        }
    }

    // MARK: - Display names (native scripts, never localized)

    func testEnglishDisplayNameIsEnglish() {
        XCTAssertEqual(AppLanguage.english.displayName, "English")
    }

    func testKoreanDisplayNameIsNativeScript() {
        XCTAssertEqual(AppLanguage.korean.displayName, "한국어")
    }

    func testJapaneseDisplayNameIsNativeScript() {
        XCTAssertEqual(AppLanguage.japanese.displayName, "日本語")
    }

    // MARK: - Identifiable

    func testIdMatchesRawValue() {
        for lang in AppLanguage.allCases {
            XCTAssertEqual(lang.id, lang.rawValue,
                            "AppLanguage.id should equal rawValue")
        }
    }

    // MARK: - matchingSystemLanguage shape contract (LANG-02)

    func testMatchingSystemLanguageReturnsSupportedCodeOrNil() {
        // matchingSystemLanguage() reads Locale.preferredLanguages; cannot mock directly.
        // Validate that, when non-nil, the result is a supported language code.
        let result = AppLanguage.matchingSystemLanguage()
        if let code = result {
            XCTAssertNotNil(AppLanguage(rawValue: code),
                           "matchingSystemLanguage() must return a supported language code or nil")
        }
        // nil is also a valid return when system language is not in the supported set
    }
}
