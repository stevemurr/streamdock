import AppKit
import Foundation

public enum KeyFaceRenderingError: LocalizedError {
    case bitmapCreationFailed
    case jpegEncodingFailed

    public var errorDescription: String? {
        switch self {
        case .bitmapCreationFailed: "Could not create a key-face bitmap."
        case .jpegEncodingFailed: "Could not encode a key face as JPEG."
        }
    }
}

@MainActor
public enum KeyFaceRenderer {
    public static func jpegData(
        for key: KeyConfiguration,
        baseDirectory: URL? = nil,
        size: Int = StreamDockProtocol.keyPixelSize,
        isActive: Bool = false
    ) throws -> Data {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size,
            pixelsHigh: size,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw KeyFaceRenderingError.bitmapCreationFailed
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let bounds = NSRect(x: 0, y: 0, width: size, height: size)
        NSColor.black.setFill()
        bounds.fill()

        if let imagePath = key.image, !imagePath.isEmpty {
            let expanded = NSString(string: imagePath).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded, relativeTo: baseDirectory)
            if let image = NSImage(contentsOf: url) {
                image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
            } else {
                drawGeneratedFace(key, in: bounds, isActive: isActive)
            }
        } else {
            drawGeneratedFace(key, in: bounds, isActive: isActive)
        }
        if isActive { drawActiveIndicator(in: bounds) }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 1.0]) else {
            throw KeyFaceRenderingError.jpegEncodingFailed
        }
        return jpeg
    }

    private static func drawActiveIndicator(in bounds: NSRect) {
        let ring = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 3, dy: 3),
            xRadius: 7,
            yRadius: 7
        )
        NSColor.systemGreen.setStroke()
        ring.lineWidth = 4
        ring.stroke()

        let dot = NSBezierPath(ovalIn: NSRect(x: bounds.maxX - 14, y: bounds.maxY - 14, width: 8, height: 8))
        NSColor.systemGreen.setFill()
        dot.fill()
    }

    private static func drawGeneratedFace(_ key: KeyConfiguration, in bounds: NSRect, isActive: Bool) {
        let color = isActive ? (key.activeColor ?? key.color) : key.color
        let base = NSColor(hex: color) ?? NSColor(calibratedRed: 0.17, green: 0.24, blue: 0.31, alpha: 1)
        let top = base.blended(withFraction: 0.18, of: .white) ?? base
        let bottom = base.blended(withFraction: 0.24, of: .black) ?? base
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
        NSGradient(starting: top, ending: bottom)?.draw(in: path, angle: -90)
        NSColor.white.withAlphaComponent(0.16).setStroke()
        path.lineWidth = 1
        path.stroke()

        let hasLabel = !key.label.isEmpty
        if let symbol = symbolName(for: key.icon),
           let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let iconSize: CGFloat = hasLabel ? 28 : 34
            let y: CGFloat = hasLabel ? 25 : 15
            let iconRect = NSRect(
                x: bounds.midX - iconSize / 2,
                y: y,
                width: iconSize,
                height: iconSize
            )
            let configured = image.withSymbolConfiguration(
                .init(pointSize: iconSize, weight: .medium)
            ) ?? image
            configured.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 0.96)
        }

        if hasLabel {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byTruncatingTail
            let text = NSAttributedString(
                string: key.label,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                    .foregroundColor: NSColor.white,
                    .paragraphStyle: paragraph,
                ]
            )
            text.draw(in: NSRect(x: 4, y: 7, width: bounds.width - 8, height: 13))
        }
    }

    private static func symbolName(for icon: String?) -> String? {
        switch icon {
        case "brightness", "sun": "sun.max.fill"
        case "bulb": "lightbulb.fill"
        case "contrast": "circle.lefthalf.filled"
        case "cycle": "arrow.triangle.2.circlepath"
        case "dot": "circle.fill"
        case "droplet": "drop.fill"
        case "gear": "gearshape.fill"
        case "lock": "lock.fill"
        case "meter": "gauge.with.dots.needle.67percent"
        case "minus": "minus"
        case "monitor": "display"
        case "moon": "moon.fill"
        case "play": "play.fill"
        case "plus": "plus"
        case "power": "power"
        case "refresh": "arrow.clockwise"
        case .none: nil
        default: "circle.fill"
        }
    }
}

private extension NSColor {
    convenience init?(hex: String) {
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard value.count == 6, let number = UInt64(value, radix: 16) else { return nil }
        self.init(
            calibratedRed: CGFloat((number >> 16) & 0xff) / 255,
            green: CGFloat((number >> 8) & 0xff) / 255,
            blue: CGFloat(number & 0xff) / 255,
            alpha: 1
        )
    }
}
