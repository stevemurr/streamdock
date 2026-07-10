import XCTest
@testable import StreamDockCore

final class ColorHexTests: XCTestCase {
    func testParsesSixDigitHex() throws {
        let components = try XCTUnwrap(ColorHex.parse("#4a4d55"))
        XCTAssertEqual(components.red, 74.0 / 255, accuracy: 1e-9)
        XCTAssertEqual(components.green, 77.0 / 255, accuracy: 1e-9)
        XCTAssertEqual(components.blue, 85.0 / 255, accuracy: 1e-9)
    }

    func testRoundTripPreservesCanonicalStrings() {
        for hex in ["#000000", "#ffffff", "#2c3e50", "#4a4d55", "#123abc", "#0080ff"] {
            guard let components = ColorHex.parse(hex) else {
                XCTFail("Failed to parse \(hex)")
                continue
            }
            XCTAssertEqual(
                ColorHex.format(red: components.red, green: components.green, blue: components.blue),
                hex
            )
        }
    }

    func testExpandsThreeDigitShorthand() throws {
        let components = try XCTUnwrap(ColorHex.parse("#4af"))
        XCTAssertEqual(
            ColorHex.format(red: components.red, green: components.green, blue: components.blue),
            "#44aaff"
        )
    }

    func testAcceptsMissingHash() throws {
        let long = try XCTUnwrap(ColorHex.parse("4a4d55"))
        XCTAssertEqual(ColorHex.format(red: long.red, green: long.green, blue: long.blue), "#4a4d55")
        let short = try XCTUnwrap(ColorHex.parse("fa0"))
        XCTAssertEqual(ColorHex.format(red: short.red, green: short.green, blue: short.blue), "#ffaa00")
    }

    func testIsCaseInsensitive() throws {
        let components = try XCTUnwrap(ColorHex.parse("#4A4D55"))
        XCTAssertEqual(
            ColorHex.format(red: components.red, green: components.green, blue: components.blue),
            "#4a4d55"
        )
    }

    func testRejectsInvalidInput() {
        let invalid = [
            "", "#", "#1", "#12", "#1234", "#12345", "#1234567", "#12345678",
            "#gggggg", "#12345g", "#zzz", "not a color", "##123456", "#12 456",
        ]
        for hex in invalid {
            XCTAssertNil(ColorHex.parse(hex), "Expected nil for \(hex)")
        }
    }

    func testFormatClampsOutOfRangeComponents() {
        XCTAssertEqual(ColorHex.format(red: -0.5, green: 1.5, blue: 0.5), "#00ff80")
        XCTAssertEqual(ColorHex.format(red: -.infinity, green: .infinity, blue: 0), "#00ff00")
        XCTAssertEqual(ColorHex.format(red: .nan, green: 0, blue: 0), "#000000")
    }

    func testFormatEmitsLowercase() {
        let formatted = ColorHex.format(red: 0.7, green: 0.8, blue: 0.9)
        XCTAssertEqual(formatted, formatted.lowercased())
        XCTAssertTrue(formatted.hasPrefix("#"))
        XCTAssertEqual(formatted.count, 7)
    }
}
