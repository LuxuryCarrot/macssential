import XCTest
@testable import macssential

/// Pure-geometry coverage for the menubar panel's live resize (QUICK-HGV-03).
///
/// The panel resize is driven by a SwiftUI geometry callback that fires as the
/// content lays out. That makes two properties safety-critical rather than
/// cosmetic: a NaN or zero height would produce an unusable frame, and a resize
/// that always reports "changed" would ping-pong the geometry callback against the
/// layout it triggers (T-HGV-06). Both are proven here, off the run loop.
final class MainPanelSizingTests: XCTestCase {

    // MARK: - fittedSize

    func testFittedSizeKeepsPanelWidth() {
        let size = MainPanelSizing.fittedSize(contentHeight: 300, availableHeight: 800)
        XCTAssertEqual(size.width, MainPanelSizing.width,
            "Panel width is fixed by MainPanelView's own .frame(width:) and must never be derived from content")
        XCTAssertEqual(size.width, 280)
    }

    func testFittedSizeUsesContentHeightWhenItFits() {
        let size = MainPanelSizing.fittedSize(contentHeight: 342.5, availableHeight: 800)
        XCTAssertEqual(size.height, 342.5, accuracy: 0.001,
            "Content that fits on screen must be shown at its natural height")
    }

    func testFittedSizeClampsToAvailableHeight() {
        let size = MainPanelSizing.fittedSize(contentHeight: 2000, availableHeight: 700)
        XCTAssertEqual(size.height, 700, accuracy: 0.001,
            "A panel taller than the screen would push Settings/Quit out of reach entirely")
    }

    func testFittedSizeRejectsNonFiniteContentHeight() {
        for bogus in [CGFloat.nan, .infinity, -.infinity] {
            let size = MainPanelSizing.fittedSize(contentHeight: bogus, availableHeight: 800)
            XCTAssertTrue(size.height.isFinite,
                "A non-finite height from an intermediate layout pass must never reach an NSView frame")
            XCTAssertEqual(size.height, MainPanelSizing.minimumHeight, accuracy: 0.001)
        }
    }

    func testFittedSizeRejectsNonPositiveContentHeight() {
        XCTAssertEqual(MainPanelSizing.fittedSize(contentHeight: 0, availableHeight: 800).height,
                       MainPanelSizing.minimumHeight, accuracy: 0.001,
            "SwiftUI reports a zero size before first layout; collapsing the panel to nothing is not acceptable")
        XCTAssertEqual(MainPanelSizing.fittedSize(contentHeight: -50, availableHeight: 800).height,
                       MainPanelSizing.minimumHeight, accuracy: 0.001)
    }

    func testFittedSizeSurvivesDegenerateAvailableHeight() {
        let size = MainPanelSizing.fittedSize(contentHeight: 300, availableHeight: 0)
        XCTAssertTrue(size.height.isFinite && size.height > 0,
            "A bogus screen height must not clamp the panel out of existence")
    }

    // MARK: - needsResize

    func testNeedsResizeIsFalseForIdenticalSizes() {
        let size = CGSize(width: 280, height: 400)
        XCTAssertFalse(MainPanelSizing.needsResize(current: size, target: size),
            "An unchanged size must not trigger a resize — that is the loop breaker")
    }

    func testNeedsResizeIsFalseBelowTolerance() {
        XCTAssertFalse(MainPanelSizing.needsResize(
            current: CGSize(width: 280, height: 400),
            target: CGSize(width: 280, height: 400.4)),
            "Sub-pixel jitter from repeated layout passes must not feed back into another resize")
    }

    func testNeedsResizeIsTrueForRealHeightChange() {
        XCTAssertTrue(MainPanelSizing.needsResize(
            current: CGSize(width: 280, height: 400),
            target: CGSize(width: 280, height: 460)),
            "A settings row appearing grows the panel by tens of points and must resize")
    }

    func testNeedsResizeIsTrueForRealWidthChange() {
        XCTAssertTrue(MainPanelSizing.needsResize(
            current: CGSize(width: 280, height: 400),
            target: CGSize(width: 320, height: 400)))
    }

    func testNeedsResizeHonoursCustomTolerance() {
        XCTAssertFalse(MainPanelSizing.needsResize(
            current: CGSize(width: 280, height: 400),
            target: CGSize(width: 280, height: 405),
            tolerance: 10))
        XCTAssertTrue(MainPanelSizing.needsResize(
            current: CGSize(width: 280, height: 400),
            target: CGSize(width: 280, height: 415),
            tolerance: 10))
    }
}
