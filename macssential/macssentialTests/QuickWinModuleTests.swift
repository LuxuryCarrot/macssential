import XCTest
@testable import macssential

// MARK: - ModuleRegistryQuickWinTests

final class ModuleRegistryQuickWinTests: XCTestCase {

    func testTotalModuleCount() {
        let registry = ModuleRegistry()
#if DEBUG
        // FinderSort is registered only in Debug builds (QUICK-KBR-02).
        let expectedCount = 10
#else
        let expectedCount = 9
#endif
        XCTAssertEqual(registry.modules.count, expectedCount, "Registry should contain \(expectedCount) modules: DockAnchor, DockAutoHide, DockRecentApps, HiddenFiles, KeyRepeat, ScrollDirection, ScreenshotAutoCopy, WindowSwitcher, KoreanFilenameNormalizer (+ FinderSort in Debug)")
    }
}
