import XCTest
@testable import macssential

final class DisplayPickerTests: XCTestCase {

    // MARK: - UserDefaults key for cleanup

    private let monitorKey = "com.macssential.module.dock-anchor.monitor"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: monitorKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: monitorKey)
        super.tearDown()
    }

    // MARK: - Test 1: DisplayInfo can be created from properties

    func testDisplayInfoCreation() {
        let info = DisplayInfo(
            id: 1,
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            name: "Built-in Display",
            hasDock: true
        )
        XCTAssertEqual(info.id, 1)
        XCTAssertEqual(info.frame.width, 1920)
        XCTAssertEqual(info.name, "Built-in Display")
        XCTAssertTrue(info.hasDock)
    }

    // MARK: - Test 2: calculateProportionalLayout scales to fit maxWidth x maxHeight

    func testCalculateProportionalLayoutSingleScreen() {
        let display = DisplayInfo(
            id: 1,
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            name: "Display 1",
            hasDock: true
        )

        let result = DisplayLayoutCalculator.calculateProportionalLayout(
            displays: [display],
            maxWidth: 228,
            maxHeight: 120
        )

        XCTAssertEqual(result.count, 1, "Should return one layout entry")
        guard result.count == 1 else { return }

        let rect = result[0].rect
        // 1920:1080 aspect ratio = 16:9
        // Scale to fit 228x120: scaleX=228/1920=0.11875, scaleY=120/1080=0.1111
        // min scale = 0.1111, so height = 1080*0.1111 = 120, width = 1920*0.1111 = 213.33
        XCTAssertLessThanOrEqual(rect.width, 228, "Width should fit within maxWidth")
        XCTAssertLessThanOrEqual(rect.height, 120, "Height should fit within maxHeight")
        XCTAssertGreaterThan(rect.width, 0)
        XCTAssertGreaterThan(rect.height, 0)
    }

    // MARK: - Test 3: Two side-by-side screens produce non-overlapping rects

    func testCalculateProportionalLayoutTwoScreens() {
        let display1 = DisplayInfo(
            id: 1,
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            name: "Display 1",
            hasDock: true
        )
        let display2 = DisplayInfo(
            id: 2,
            frame: CGRect(x: 1920, y: 0, width: 2560, height: 1440),
            name: "Display 2",
            hasDock: false
        )

        let result = DisplayLayoutCalculator.calculateProportionalLayout(
            displays: [display1, display2],
            maxWidth: 228,
            maxHeight: 120
        )

        XCTAssertEqual(result.count, 2, "Should return two layout entries")
        guard result.count == 2 else { return }

        let rect1 = result[0].rect
        let rect2 = result[1].rect

        // Rects should not overlap
        XCTAssertFalse(
            rect1.intersects(rect2),
            "Two side-by-side screens should produce non-overlapping rects. rect1=\(rect1), rect2=\(rect2)"
        )

        // Both should fit within bounds
        XCTAssertLessThanOrEqual(rect1.maxX, 228 + 0.01)
        XCTAssertLessThanOrEqual(rect2.maxX, 228 + 0.01)
        XCTAssertLessThanOrEqual(rect1.maxY, 120 + 0.01)
        XCTAssertLessThanOrEqual(rect2.maxY, 120 + 0.01)
    }

    // MARK: - Test 4: Single screen proportionally fills available width

    func testSingleScreenFillsProportionally() {
        let display = DisplayInfo(
            id: 1,
            frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            name: "Wide Display",
            hasDock: true
        )

        let result = DisplayLayoutCalculator.calculateProportionalLayout(
            displays: [display],
            maxWidth: 228,
            maxHeight: 120
        )

        XCTAssertEqual(result.count, 1)
        guard result.count == 1 else { return }

        let rect = result[0].rect
        // Aspect ratio 2560:1440 = 16:9
        // scaleX = 228/2560 = 0.0891, scaleY = 120/1440 = 0.0833
        // min scale = 0.0833, width = 2560*0.0833 = 213.3, height = 120
        // Centered: offsetX = (228-213.3)/2 = 7.35
        XCTAssertEqual(rect.height, 120, accuracy: 0.1, "Should use full height for 16:9 aspect")
    }

    // MARK: - Test 5: Monitor selection persists to UserDefaults

    func testMonitorSelectionPersistence() {
        let displayID: UInt32 = 12345
        UserDefaults.standard.set(displayID, forKey: monitorKey)

        let stored = UserDefaults.standard.object(forKey: monitorKey) as? UInt32
        XCTAssertEqual(stored, displayID, "Monitor ID should persist as UInt32")
    }

    // MARK: - Test 6: Reading persisted monitor ID returns saved value

    func testMonitorSelectionRoundTrip() {
        let displayID: UInt32 = 67890
        UserDefaults.standard.set(displayID, forKey: monitorKey)

        // Read back
        let value = UserDefaults.standard.object(forKey: monitorKey) as? UInt32
            ?? UInt32(UserDefaults.standard.integer(forKey: monitorKey))
        XCTAssertEqual(value, displayID, "Should round-trip monitor ID through UserDefaults")
    }

    // MARK: - Test 7: Empty displays array returns empty layout

    func testEmptyDisplaysReturnsEmptyLayout() {
        let result = DisplayLayoutCalculator.calculateProportionalLayout(
            displays: [],
            maxWidth: 228,
            maxHeight: 120
        )
        XCTAssertTrue(result.isEmpty, "Empty input should produce empty output")
    }

    // MARK: - Test 8: Layout maintains relative positioning

    func testLayoutMaintainsRelativePositioning() {
        // Display 2 is to the right of display 1
        let display1 = DisplayInfo(
            id: 1,
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            name: "Left",
            hasDock: true
        )
        let display2 = DisplayInfo(
            id: 2,
            frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080),
            name: "Right",
            hasDock: false
        )

        let result = DisplayLayoutCalculator.calculateProportionalLayout(
            displays: [display1, display2],
            maxWidth: 228,
            maxHeight: 120
        )

        XCTAssertEqual(result.count, 2)
        guard result.count == 2 else { return }
        // Display 2 rect should be to the right of display 1 rect
        XCTAssertGreaterThan(
            result[1].rect.minX, result[0].rect.minX,
            "Right display should have larger minX"
        )
    }
}
