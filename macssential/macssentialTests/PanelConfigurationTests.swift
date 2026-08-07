import XCTest
@testable import macssential

@MainActor
final class PanelConfigurationTests: XCTestCase {

    // Real registered module IDs (registration order).
    private let allIDs = [
        "dock-anchor",
        "dock-autohide",
        "dock-recent-apps",
        "hidden-files",
        "scroll-direction",
        "screenshot-auto-copy",
        "korean-filename-normalizer",
    ]

    private let suiteName = "com.macssential.tests.panelconfig"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Pure default helper

    func testDefaultVisibleIDsExcludesKoreanNormalizerWhenNotKorean() {
        let visible = PanelConfiguration.defaultVisibleIDs(allModuleIDs: allIDs, language: .english)
        XCTAssertFalse(visible.contains("korean-filename-normalizer"),
                       "Korean Filename Normalizer must be hidden by default in non-Korean locales")
    }

    func testDefaultVisibleIDsIncludesKoreanNormalizerWhenKorean() {
        let visible = PanelConfiguration.defaultVisibleIDs(allModuleIDs: allIDs, language: .korean)
        XCTAssertTrue(visible.contains("korean-filename-normalizer"),
                      "Korean Filename Normalizer must be visible by default in Korean locale")
    }

    func testDefaultVisibleIDsIncludesNormalizerWhenJapanese() {
        let visible = PanelConfiguration.defaultVisibleIDs(allModuleIDs: allIDs, language: .japanese)
        XCTAssertTrue(visible.contains("korean-filename-normalizer"),
                      "Filename Normalizer must be visible by default for Japanese (dakuten NFD issue)")
    }

    func testDefaultVisibleIDsIncludesNormalizerWhenSystemLanguageAffected() {
        // English UI, but the system prefers an NFD-affected language (e.g. Vietnamese).
        let visible = PanelConfiguration.defaultVisibleIDs(
            allModuleIDs: allIDs, language: .english, systemAffectedByNFD: true)
        XCTAssertTrue(visible.contains("korean-filename-normalizer"),
                      "Filename Normalizer must default-show when a preferred system language is NFD-affected")
    }

    func testDefaultVisibleIDsAlwaysExcludesScrollDirection() {
        let visibleNonKorean = PanelConfiguration.defaultVisibleIDs(allModuleIDs: allIDs, language: .english)
        let visibleKorean = PanelConfiguration.defaultVisibleIDs(allModuleIDs: allIDs, language: .korean)
        XCTAssertFalse(visibleNonKorean.contains("scroll-direction"),
                       "Scroll Direction is relocated to Settings and must be hidden from the panel by default")
        XCTAssertFalse(visibleKorean.contains("scroll-direction"),
                       "Scroll Direction default-hidden regardless of locale")
    }

    func testDefaultVisibleIDsIncludesOtherModules() {
        let visible = PanelConfiguration.defaultVisibleIDs(allModuleIDs: allIDs, language: .english)
        for id in ["dock-anchor", "dock-autohide", "dock-recent-apps", "hidden-files", "screenshot-auto-copy"] {
            XCTAssertTrue(visible.contains(id), "\(id) should be visible by default")
        }
    }

    // MARK: - Instance default behavior (no stored value)

    func testIsVisibleFollowsDefaultWhenNoStoredValue() {
        let config = PanelConfiguration(allModuleIDs: allIDs, language: .english, defaults: defaults)
        XCTAssertTrue(config.isVisible("dock-anchor"))
        XCTAssertFalse(config.isVisible("korean-filename-normalizer"))
        XCTAssertFalse(config.isVisible("scroll-direction"))
    }

    // MARK: - Persistence round-trip

    func testSetVisiblePersistsAcrossInstances() {
        let config = PanelConfiguration(allModuleIDs: allIDs, language: .english, defaults: defaults)
        XCTAssertTrue(config.isVisible("dock-anchor"))

        config.setVisible("dock-anchor", false)
        XCTAssertFalse(config.isVisible("dock-anchor"))

        // Fresh instance reading the same defaults should see the persisted choice.
        let reloaded = PanelConfiguration(allModuleIDs: allIDs, language: .english, defaults: defaults)
        XCTAssertFalse(reloaded.isVisible("dock-anchor"),
                       "setVisible should persist and be read back by a fresh instance")
    }

    func testStoredValueWinsOverKoreanDefault() {
        // Seed a stored set that explicitly includes korean-filename-normalizer.
        let stored = PanelConfiguration(allModuleIDs: allIDs, language: .korean, defaults: defaults)
        stored.setVisible("korean-filename-normalizer", true) // persists a stored array

        // A non-Korean instance must honor the stored value, not the non-Korean default.
        let reloaded = PanelConfiguration(allModuleIDs: allIDs, language: .english, defaults: defaults)
        XCTAssertTrue(reloaded.isVisible("korean-filename-normalizer"),
                      "Once a stored value exists, it wins even for korean-filename-normalizer regardless of language")
    }
}
