// Draws the StreamDock application icon and writes every size the asset
// catalog needs into Resources/Assets.xcassets/AppIcon.appiconset.
//
// Regenerate after design tweaks with:
//   DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
//     swift macos/Scripts/GenerateAppIcon.swift
//
// The artwork follows the macOS Big Sur+ template: a 1024-pt canvas whose
// squircle occupies the central 824×824 with a baked-in drop shadow. The
// design is a zoomed-in deck: a 3×3 grid of keys, mostly dark, with a green
// power key at the center and two accent keys on the diagonal — the same
// palette the editor renders.

import AppKit

// MARK: - Geometry (all in 1024-pt master space)

let canvas: CGFloat = 1024
let squircle = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircleRadius: CGFloat = 185
let gridInset: CGFloat = 96
let keySize: CGFloat = 184
let keyGap: CGFloat = 40
let keyRadius: CGFloat = 42

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: alpha
    )
}

struct KeyStyle {
    let top: NSColor
    let bottom: NSColor
    let glow: NSColor?
}

let darkKey = KeyStyle(top: color(0x454C5C), bottom: color(0x2E3440), glow: nil)
let greenKey = KeyStyle(top: color(0x3DDC84), bottom: color(0x0FA968), glow: color(0x2ECC71, 0.55))
let amberKey = KeyStyle(top: color(0xFFC145), bottom: color(0xE58E1A), glow: color(0xF5A623, 0.45))
let azureKey = KeyStyle(top: color(0x4FB8FF), bottom: color(0x1D7DE0), glow: color(0x3498DB, 0.45))

/// Style per (column, row); rows count from the bottom.
func style(column: Int, row: Int) -> KeyStyle {
    switch (column, row) {
    case (1, 1): greenKey
    case (2, 2): amberKey
    case (0, 0): azureKey
    default: darkKey
    }
}

// MARK: - Drawing

func drawIcon() {
    guard let context = NSGraphicsContext.current?.cgContext else { return }

    // Deck body with its baked-in drop shadow.
    let body = NSBezierPath(
        roundedRect: squircle,
        xRadius: squircleRadius,
        yRadius: squircleRadius
    )
    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -14),
        blur: 36,
        color: NSColor.black.withAlphaComponent(0.35).cgColor
    )
    color(0x232833).setFill()
    body.fill()
    context.restoreGState()

    NSGradient(colors: [color(0x343B4B), color(0x232833), color(0x161A22)])?
        .draw(in: body, angle: -90)

    // Faint rim so the body edge reads against dark backgrounds.
    NSColor.white.withAlphaComponent(0.07).setStroke()
    let rim = NSBezierPath(
        roundedRect: squircle.insetBy(dx: 2, dy: 2),
        xRadius: squircleRadius - 2,
        yRadius: squircleRadius - 2
    )
    rim.lineWidth = 3
    rim.stroke()

    // Key grid.
    let origin = squircle.origin.x + gridInset
    for row in 0..<3 {
        for column in 0..<3 {
            let rect = CGRect(
                x: origin + CGFloat(column) * (keySize + keyGap),
                y: origin + CGFloat(row) * (keySize + keyGap),
                width: keySize,
                height: keySize
            )
            draw(key: style(column: column, row: row), in: rect, context: context)
        }
    }

    drawPowerSymbol(context: context)
}

func draw(key: KeyStyle, in rect: CGRect, context: CGContext) {
    let path = NSBezierPath(roundedRect: rect, xRadius: keyRadius, yRadius: keyRadius)

    context.saveGState()
    if let glow = key.glow {
        context.setShadow(offset: .zero, blur: 30, color: glow.cgColor)
    } else {
        context.setShadow(
            offset: CGSize(width: 0, height: -7),
            blur: 12,
            color: NSColor.black.withAlphaComponent(0.35).cgColor
        )
    }
    key.bottom.setFill()
    path.fill()
    context.restoreGState()

    NSGradient(starting: key.top, ending: key.bottom)?.draw(in: path, angle: -90)

    // Top sheen keeps the keys from looking flat.
    NSColor.white.withAlphaComponent(key.glow == nil ? 0.10 : 0.22).setStroke()
    let sheen = NSBezierPath(
        roundedRect: rect.insetBy(dx: 2.5, dy: 2.5),
        xRadius: keyRadius - 2.5,
        yRadius: keyRadius - 2.5
    )
    sheen.lineWidth = 3
    sheen.stroke()
}

func drawPowerSymbol(context: CGContext) {
    let center = CGPoint(x: canvas / 2, y: canvas / 2)
    let radius: CGFloat = 46

    context.saveGState()
    context.setShadow(
        offset: .zero,
        blur: 14,
        color: NSColor.black.withAlphaComponent(0.28).cgColor
    )
    NSColor.white.setStroke()

    let arc = NSBezierPath()
    arc.lineWidth = 16
    arc.lineCapStyle = .round
    // Full circle except a gap at the top for the stem.
    arc.appendArc(withCenter: center, radius: radius, startAngle: 118, endAngle: 62)
    arc.stroke()

    let stem = NSBezierPath()
    stem.lineWidth = 16
    stem.lineCapStyle = .round
    stem.move(to: CGPoint(x: center.x, y: center.y + 14))
    stem.line(to: CGPoint(x: center.x, y: center.y + radius + 26))
    stem.stroke()
    context.restoreGState()
}

// MARK: - Rendering and output

func bitmap(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixels, height: pixels)
    return rep
}

func write(_ rep: NSBitmapImageRep, to url: URL) throws {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("PNG encoding failed for \(url.lastPathComponent)")
    }
    try data.write(to: url)
}

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
let outputDirectory = scriptURL
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Resources/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

// Master render at 1024, then high-quality downscales for the smaller sizes.
let master = bitmap(pixels: 1024)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: master)
drawIcon()
NSGraphicsContext.restoreGraphicsState()
try write(master, to: outputDirectory.appendingPathComponent("icon_1024.png"))

for pixels in [16, 32, 64, 128, 256, 512] {
    let rep = bitmap(pixels: pixels)
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    master.draw(
        in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
        from: NSRect(x: 0, y: 0, width: 1024, height: 1024),
        operation: .copy,
        fraction: 1,
        respectFlipped: false,
        hints: [.interpolation: NSImageInterpolation.high.rawValue]
    )
    NSGraphicsContext.restoreGraphicsState()
    try write(rep, to: outputDirectory.appendingPathComponent("icon_\(pixels).png"))
}

print("Wrote icon set to \(outputDirectory.path)")
