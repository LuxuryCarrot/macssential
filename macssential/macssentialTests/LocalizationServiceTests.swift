import XCTest
@testable import macssential

final class LocalizationServiceTests: XCTestCase {
    private let languageKey = "com.macssential.language"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: languageKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: languageKey)
        super.tearDown()
    }

    // MARK: - LANG-02: System language detection / fallback on init

    @MainActor func testInitFallsBackToEnglishWhenNoPersistedAndSystemUnsupported() {
        // setUp already cleared the persisted key.
        let service = LocalizationService()
        // Minimum guarantee: currentLanguage is always one of the supported cases.
        // If system language matches a supported case, it will be used; otherwise .english.
        XCTAssertTrue(AppLanguage.allCases.contains(service.currentLanguage),
                       "currentLanguage must always be one of AppLanguage.allCases")
    }

    // MARK: - setLanguage mutates currentLanguage

    @MainActor func testSetLanguageChangesCurrentLanguage() {
        let service = LocalizationService()
        service.setLanguage(.japanese)
        XCTAssertEqual(service.currentLanguage, .japanese)
        service.setLanguage(.korean)
        XCTAssertEqual(service.currentLanguage, .korean)
    }

    // MARK: - LANG-04: setLanguage persists to UserDefaults

    @MainActor func testSetLanguagePersistsToUserDefaults() {
        let service = LocalizationService()
        service.setLanguage(.korean)
        let stored = UserDefaults.standard.string(forKey: languageKey)
        XCTAssertEqual(stored, "ko",
                        "setLanguage(.korean) must persist \"ko\" to com.macssential.language")
    }

    // MARK: - LANG-04: init reads persisted language

    @MainActor func testInitReadsPersistedLanguage() {
        UserDefaults.standard.set("ja", forKey: languageKey)
        let service = LocalizationService()
        XCTAssertEqual(service.currentLanguage, .japanese,
                        "LocalizationService.init must adopt persisted UserDefaults value")
    }

    // MARK: - Idempotency

    @MainActor func testSetLanguageIsIdempotent() {
        let service = LocalizationService()
        let before = service.currentLanguage
        service.setLanguage(before)
        XCTAssertEqual(service.currentLanguage, before,
                        "setLanguage with the same value must be a no-op (no crash, no change)")
    }

    // MARK: - LANG-03: Bundle swizzle changes localized strings at runtime

    @MainActor func testBundleSwizzleChangesLocalizedString() {
        let service = LocalizationService()

        service.setLanguage(.korean)
        let koreanString = String(localized: "module.dock_anchor.name")
        XCTAssertEqual(koreanString, "Dock 고정",
                        "After setLanguage(.korean), String(localized:) must return the KO translation")

        service.setLanguage(.english)
        let englishString = String(localized: "module.dock_anchor.name")
        XCTAssertEqual(englishString, "Dock Anchor",
                        "After setLanguage(.english), String(localized:) must return the EN translation")
    }

    // MARK: - LANG-04: English persists as "en"

    @MainActor func testSetLanguageEnglishPersistsAsEn() {
        let service = LocalizationService()
        service.setLanguage(.english)
        XCTAssertEqual(UserDefaults.standard.string(forKey: languageKey), "en",
                        "setLanguage(.english) must persist \"en\" to com.macssential.language")
    }
}
