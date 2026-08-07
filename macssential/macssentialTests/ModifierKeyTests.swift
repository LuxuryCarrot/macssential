import XCTest
import CoreGraphics
@testable import macssential

final class ModifierKeyTests: XCTestCase {

    // MARK: - Test 6: allCases has exactly 3 cases

    func testAllCasesHasExactlyThreeCases() {
        XCTAssertEqual(ModifierKeyOption.allCases.count, 3,
                        "ModifierKeyOption should have exactly 3 cases (option, control, command)")
        XCTAssertTrue(ModifierKeyOption.allCases.contains(.option))
        XCTAssertTrue(ModifierKeyOption.allCases.contains(.control))
        XCTAssertTrue(ModifierKeyOption.allCases.contains(.command))
    }

    // MARK: - Test 7: option maps to maskAlternate

    func testOptionEventFlagsIsMaskAlternate() {
        XCTAssertEqual(ModifierKeyOption.option.eventFlags, CGEventFlags.maskAlternate)
    }

    // MARK: - Test 8: control maps to maskControl

    func testControlEventFlagsIsMaskControl() {
        XCTAssertEqual(ModifierKeyOption.control.eventFlags, CGEventFlags.maskControl)
    }

    // MARK: - Test 9: command maps to maskCommand

    func testCommandEventFlagsIsMaskCommand() {
        XCTAssertEqual(ModifierKeyOption.command.eventFlags, CGEventFlags.maskCommand)
    }

    // MARK: - Test 10: option displayName contains Unicode symbol

    func testOptionDisplayNameContainsUnicodeSymbol() {
        let name = ModifierKeyOption.option.displayName
        XCTAssertTrue(name.contains("\u{2325}"),
                       "Option displayName should contain the Option symbol (U+2325)")
    }

    // MARK: - Test 11: RawRepresentable round-trip

    func testRawRepresentableRoundTrip() {
        for option in ModifierKeyOption.allCases {
            let raw = option.rawValue
            let restored = ModifierKeyOption(rawValue: raw)
            XCTAssertEqual(restored, option,
                            "ModifierKeyOption should round-trip through rawValue")
        }
    }

    // MARK: - Test 12: UserDefaults persistence

    func testUserDefaultsPersistence() {
        let defaults = UserDefaults.standard
        let key = ModifierKeyOption.defaultsKey

        // Save .control
        defaults.set(ModifierKeyOption.control.rawValue, forKey: key)

        // Read back
        let stored = defaults.string(forKey: key)
        XCTAssertNotNil(stored)
        let restored = ModifierKeyOption(rawValue: stored!) ?? .option
        XCTAssertEqual(restored, .control,
                        "Should persist and restore .control from UserDefaults")

        // Clean up
        defaults.removeObject(forKey: key)
    }
}
