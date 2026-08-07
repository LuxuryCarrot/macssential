import XCTest
@testable import macssential

// MARK: - ModuleRegistryQuickWinTests

final class ModuleRegistryQuickWinTests: XCTestCase {

    func testTotalModuleCount() {
        let registry = ModuleRegistry()
        XCTAssertEqual(registry.modules.count, 8, "Registry should contain 8 modules: DockAnchor, DockAutoHide, DockRecentApps, HiddenFiles, KeyRepeat, ScrollDirection, ScreenshotAutoCopy, KoreanFilenameNormalizer")
    }
}
