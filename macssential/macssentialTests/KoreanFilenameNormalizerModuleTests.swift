import XCTest
import Foundation
@testable import macssential

final class KoreanFilenameNormalizerModuleTests: XCTestCase {

    private let allKeys = [
        "com.macssential.module.kfn.enabled",
        "com.macssential.module.kfn.watchedFolders",
    ]

    override func setUp() {
        super.setUp()
        for key in allKeys { UserDefaults.standard.removeObject(forKey: key) }
    }

    override func tearDown() {
        for key in allKeys { UserDefaults.standard.removeObject(forKey: key) }
        super.tearDown()
    }

    // MARK: - Protocol Conformance (KFN-01)

    func testProtocolConformance() {
        let module = KoreanFilenameNormalizerModule()
        XCTAssertEqual(module.id, "korean-filename-normalizer")
        XCTAssertFalse(module.name.isEmpty)
        XCTAssertEqual(module.icon, "character.cursor.ibeam")
        XCTAssertTrue(module.isAvailable)
        XCTAssertFalse(module.requiresAccessibilityPermission)
    }

    // MARK: - Default State

    func testDefaultWatchedFolderIsDownloads() {
        let module = KoreanFilenameNormalizerModule()
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads").path
        XCTAssertEqual(module.watchedFolders, [expected])
    }

    // MARK: - UserDefaults Persistence

    func testWatchedFoldersPersistenceAcrossInstances() {
        let module1 = KoreanFilenameNormalizerModule()
        module1.watchedFolders = ["/tmp/test-kfn"]

        let module2 = KoreanFilenameNormalizerModule()
        XCTAssertEqual(module2.watchedFolders, ["/tmp/test-kfn"])
    }

    func testEnabledPersistenceAcrossInstances() {
        let module1 = KoreanFilenameNormalizerModule()
        module1.isEnabled = true

        let module2 = KoreanFilenameNormalizerModule()
        XCTAssertTrue(module2.isEnabled)
    }

    // MARK: - NFC Detection (KFN-03)

    func testNeedsNFCNormalization_withNFDString_returnsTrue() {
        // Produce NFD Korean: "한" decomposed = U+1112 + U+1161 + U+11AB (3 code points)
        let nfd = "\u{1112}\u{1161}\u{11AB}"  // NFD "한"
        XCTAssertTrue(KoreanFilenameNormalizerModule.needsNFCNormalization(nfd))
    }

    func testNeedsNFCNormalization_withNFCString_returnsFalse() {
        let nfc = "한글.pdf"  // NFC precomposed
        XCTAssertFalse(KoreanFilenameNormalizerModule.needsNFCNormalization(nfc))
    }

    func testContainsHangul_withNFCSyllables_returnsTrue() {
        XCTAssertTrue(KoreanFilenameNormalizerModule.containsHangul("한글.pdf"))
    }

    func testContainsHangul_withNFDJamo_returnsTrue() {
        let nfd = "\u{1112}\u{1161}\u{11AB}"  // NFD Jamo range U+1100-11FF
        XCTAssertTrue(KoreanFilenameNormalizerModule.containsHangul(nfd))
    }

    func testContainsHangul_withEnglish_returnsFalse() {
        XCTAssertFalse(KoreanFilenameNormalizerModule.containsHangul("hello.pdf"))
    }

    // MARK: - Japanese dakuten (NFD kana) detection

    func testContainsDecomposedKanaVoicing_withNFDDakuten_returnsTrue() {
        // NFD "が" = か (U+304B) + combining voiced mark (U+3099)
        let nfd = "\u{304B}\u{3099}.pdf"
        XCTAssertTrue(KoreanFilenameNormalizerModule.containsDecomposedKanaVoicing(nfd))
    }

    func testContainsDecomposedKanaVoicing_withPrecomposedKana_returnsFalse() {
        XCTAssertFalse(KoreanFilenameNormalizerModule.containsDecomposedKanaVoicing("がぱ.pdf"))
    }

    func testContainsAffectedScript_coversHangulAndDecomposedKana() {
        XCTAssertTrue(KoreanFilenameNormalizerModule.containsAffectedScript("한글.pdf"))
        XCTAssertTrue(KoreanFilenameNormalizerModule.containsAffectedScript("\u{304B}\u{3099}.pdf"))
        XCTAssertFalse(KoreanFilenameNormalizerModule.containsAffectedScript("hello.pdf"))
    }

    func testNeedsNFCNormalization_withNFDDakuten_returnsTrue() {
        let nfd = "\u{304B}\u{3099}.pdf"  // NFD "が.pdf"
        XCTAssertTrue(KoreanFilenameNormalizerModule.needsNFCNormalization(nfd))
    }

    // MARK: - Language relevance

    func testRelevance_appLanguageAffected() {
        XCTAssertTrue(KoreanFilenameNormalizerModule.isRelevant(appLanguage: .korean, systemLanguages: ["en-US"]))
        XCTAssertTrue(KoreanFilenameNormalizerModule.isRelevant(appLanguage: .japanese, systemLanguages: ["en-US"]))
    }

    func testRelevance_systemLanguageAffected() {
        // English UI, but the user's system prefers an NFD-affected language.
        for codes in [["vi-VN"], ["fr-FR"], ["de-DE"], ["el-GR"], ["ru-RU"], ["en-US", "vi-VN"]] {
            XCTAssertTrue(
                KoreanFilenameNormalizerModule.isRelevant(appLanguage: .english, systemLanguages: codes),
                "Normalizer must be shown when system languages \(codes) are NFD-affected")
        }
    }

    func testRelevance_unaffectedEverywhere_returnsFalse() {
        XCTAssertFalse(
            KoreanFilenameNormalizerModule.isRelevant(appLanguage: .english, systemLanguages: ["en-US", "id-ID"]),
            "The NFD filename normalizer must be hidden when neither app nor system languages are affected")
    }

    // MARK: - Combining-diacritic (Latin/Greek/Cyrillic NFD) detection

    func testContainsCombiningDiacritics_withNFDVietnamese_returnsTrue() {
        // NFD "Việt" = V + i + e+U+0302+U+0323 + t
        let nfd = "Vie\u{0302}\u{0323}t.txt"
        XCTAssertTrue(KoreanFilenameNormalizerModule.containsCombiningDiacritics(nfd))
        XCTAssertTrue(KoreanFilenameNormalizerModule.containsAffectedScript(nfd))
        XCTAssertTrue(KoreanFilenameNormalizerModule.needsNFCNormalization(nfd))
    }

    func testContainsCombiningDiacritics_withNFDFrench_returnsTrue() {
        let nfd = "cafe\u{0301}.pdf"  // NFD "café.pdf" = e+U+0301
        XCTAssertTrue(KoreanFilenameNormalizerModule.containsAffectedScript(nfd))
    }

    func testContainsCombiningDiacritics_withPrecomposedLatin_returnsFalse() {
        XCTAssertFalse(KoreanFilenameNormalizerModule.containsCombiningDiacritics("café.pdf"),
            "Precomposed é must not register as decomposed")
    }

    func testNFDFilenameIssue_affectedCodes() {
        XCTAssertTrue(NFDFilenameIssue.affectsSystemLanguages(["vi-VN"]))
        XCTAssertTrue(NFDFilenameIssue.affectsSystemLanguages(["pt-BR"]))
        XCTAssertFalse(NFDFilenameIssue.affectsSystemLanguages(["en-US", "zh-Hans-CN"]),
            "English and Chinese are not NFD-affected")
        XCTAssertFalse(NFDFilenameIssue.affectsSystemLanguages([]))
    }

    // MARK: - Settings View

    @MainActor func testSettingsViewIsNotNil() {
        let module = KoreanFilenameNormalizerModule()
        XCTAssertNotNil(module.settingsView,
            "KoreanFilenameNormalizerModule must provide a settings view for watched folder configuration")
    }

    // MARK: - Darwin.rename() Integration (KFN-05)

    func testDarwinRename_NFDtoNFC_onRealFile() throws {
        // Build paths using string concatenation so URL NFC-normalization never touches them.
        // URL.appendingPathComponent silently normalizes NFD→NFC, which would make this
        // test create a NFC file and test a trivial NFC→NFC rename. We bypass URL entirely.
        let tmpDir = FileManager.default.temporaryDirectory.path
        let nfd = "\u{1112}\u{1161}\u{11AB}.txt"   // NFD "한.txt" — 3 Jamo code points
        let nfc = "한.txt"                           // NFC "한.txt" — 1 syllable code point
        let srcPath = tmpDir + "/" + nfd
        let dstPath = tmpDir + "/" + nfc

        // Create file with NFD name using Darwin.open so the name is never NFC-normalized.
        let fd = srcPath.withCString { Darwin.open($0, O_CREAT | O_WRONLY | O_TRUNC, 0o644) }
        XCTAssertGreaterThanOrEqual(fd, 0, "Failed to create NFD test file")
        Darwin.close(fd)
        defer {
            srcPath.withCString { _ = Darwin.unlink($0) }
            dstPath.withCString { _ = Darwin.unlink($0) }
        }

        // Verify the file was stored with NFD bytes by reading the directory.
        var foundNFD = false
        if let dir = Darwin.opendir(tmpDir) {
            defer { Darwin.closedir(dir) }
            while let entry = Darwin.readdir(dir) {
                let name = withUnsafePointer(to: entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
                        String(cString: $0)
                    }
                }
                if name == nfd { foundNFD = true; break }
            }
        }
        XCTAssertTrue(foundNFD, "File should be stored with NFD bytes before rename")

        // Two-step rename (mirrors processFileEvent fix for APFS no-op workaround)
        let tmpName = tmpDir + "/.kfn_test_\(UUID().uuidString)"
        let r1 = srcPath.withCString { s in tmpName.withCString { t in Darwin.rename(s, t) } }
        XCTAssertEqual(r1, 0)
        let r2 = tmpName.withCString { t in dstPath.withCString { d in Darwin.rename(t, d) } }
        XCTAssertEqual(r2, 0, "Darwin.rename() two-step should return 0 on success")

        // Verify NFC name is now stored in the directory.
        var foundNFC = false
        if let dir = Darwin.opendir(tmpDir) {
            defer { Darwin.closedir(dir) }
            while let entry = Darwin.readdir(dir) {
                let name = withUnsafePointer(to: entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
                        String(cString: $0)
                    }
                }
                if name == nfc { foundNFC = true; break }
            }
        }
        XCTAssertTrue(foundNFC, "File should be stored with NFC bytes after rename")
    }
}
