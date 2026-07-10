import Foundation

/// Parses and formats the `#rrggbb` hex color strings used by key configurations.
public enum ColorHex {
    /// Parses a hex color string into sRGB components in `0...1`.
    ///
    /// Accepts `#rrggbb`, `rrggbb`, and shorthand `#rgb`/`rgb` (each digit is
    /// doubled), case-insensitively. Returns `nil` for anything else — wrong
    /// length, non-hex characters — rather than guessing.
    public static func parse(_ hex: String) -> (red: Double, green: Double, blue: Double)? {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 3 {
            text = text.map { String(repeating: $0, count: 2) }.joined()
        }
        guard text.count == 6 else { return nil }

        var values: [Int] = []
        values.reserveCapacity(6)
        for character in text {
            guard let value = character.hexDigitValue else { return nil }
            values.append(value)
        }
        func channel(_ index: Int) -> Double {
            Double(values[index] * 16 + values[index + 1]) / 255
        }
        return (red: channel(0), green: channel(2), blue: channel(4))
    }

    /// Formats sRGB components as a lowercase `#rrggbb` string, clamping each
    /// component to `0...1` first.
    public static func format(red: Double, green: Double, blue: Double) -> String {
        func byte(_ value: Double) -> Int {
            guard !value.isNaN else { return 0 }
            return Int((min(max(value, 0), 1) * 255).rounded())
        }
        return String(format: "#%02x%02x%02x", byte(red), byte(green), byte(blue))
    }
}
