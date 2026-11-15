// Draws the backgrounds made in code, each in an editor theme's palette, as 3840×2400 JPEGs in
// App/Resources/Backgrounds. Run from anywhere:  swift scripts/generate-backgrounds.swift
// Seeded, so a rerun draws the same pictures.
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let width = 3840, height = 2400
let here = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../App/Resources/Backgrounds").standardized

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// A small seeded generator (SplitMix64), so every run draws the same stars and grain.
struct Seeded: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func draw(_ name: String, _ body: (CGContext, inout Seeded) -> Void) {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    var random = Seeded(state: UInt64(name.utf8.reduce(7) { $0 &* 31 &+ UInt64($1) }))
    body(context, &random)
    grain(context, &random)
    let url = here.appending(path: "\(name).jpg")
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
    CGImageDestinationFinalize(destination)
    print("wrote \(url.lastPathComponent)")
}

func fill(_ context: CGContext, top: UInt32, bottom: UInt32) {
    let gradient = CGGradient(colorsSpace: nil, colors: [rgb(bottom), rgb(top)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: height), options: [])
}

/// A soft round light, full at its middle and gone at `radius`.
func glow(_ context: CGContext, _ hex: UInt32, alpha: CGFloat, at centre: CGPoint, radius: CGFloat) {
    let gradient = CGGradient(colorsSpace: nil, colors: [rgb(hex, alpha), rgb(hex, alpha * 0.35), rgb(hex, 0)] as CFArray, locations: [0, 0.45, 1])!
    context.drawRadialGradient(gradient, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: radius, options: [])
}

/// Faint film grain, so the big gradients don't band.
func grain(_ context: CGContext, _ random: inout Seeded) {
    for _ in 0..<60_000 {
        let light = Bool.random(using: &random)
        context.setFillColor(light ? rgb(0xFFFFFF, 0.035) : rgb(0x000000, 0.05))
        context.fill(CGRect(x: .random(in: 0..<CGFloat(width), using: &random), y: .random(in: 0..<CGFloat(height), using: &random), width: 2, height: 2))
    }
}

/// A line across the picture that rises and falls with a few sines, for ridges and waves.
func wave(_ context: CGContext, base: CGFloat, parts: [(amplitude: CGFloat, length: CGFloat, phase: CGFloat)]) -> CGPath {
    let path = CGMutablePath()
    for x in stride(from: CGFloat(-20), through: CGFloat(width + 20), by: 8) {
        let y = base + parts.reduce(0) { $0 + $1.amplitude * sin(x / $1.length + $1.phase) }
        x < 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    return path
}

// Nord: frost-coloured contour lines over Polar Night, each following the one below so they never
// cross, like a map of a hillside at dusk.
draw("nord") { context, random in
    fill(context, top: 0x3B4252, bottom: 0x242933)
    glow(context, 0x88C0D0, alpha: 0.2, at: CGPoint(x: 2700, y: 1500), radius: 1700)
    let frost: [UInt32] = [0x8FBCBB, 0x88C0D0, 0x81A1C1, 0x5E81AC]
    let parts = (0..<4).map { _ in (amplitude: CGFloat.random(in: 60...160, using: &random), length: CGFloat.random(in: 300...900, using: &random), phase: CGFloat.random(in: 0...6.28, using: &random)) }
    for index in 0..<60 {
        let along = CGFloat(index) / 59
        // Each line a little calmer and a little shifted from the last, so they fan apart smoothly.
        let shaped = parts.enumerated().map { offset, part in (amplitude: part.amplitude * (1.2 - along * 0.8), length: part.length, phase: part.phase + along * CGFloat(offset + 1) * 0.6) }
        context.addPath(wave(context, base: 120 + along * 2150, parts: shaped))
        context.setStrokeColor(rgb(frost[index % frost.count], index % 5 == 0 ? 0.55 : 0.22))
        context.setLineWidth(index % 5 == 0 ? 4 : 2.5)
        context.strokePath()
    }
}

// Catppuccin Mocha: soft pools of mauve, blue, pink and peach on Base.
draw("catppuccin") { context, random in
    fill(context, top: 0x1E1E2E, bottom: 0x11111B)
    let lights: [(UInt32, CGPoint, CGFloat)] = [
        (0xCBA6F7, CGPoint(x: 900, y: 1700), 1700), (0x89B4FA, CGPoint(x: 3000, y: 1900), 1500),
        (0xF5C2E7, CGPoint(x: 2300, y: 600), 1300), (0xFAB387, CGPoint(x: 400, y: 300), 900),
        (0x94E2D5, CGPoint(x: 3500, y: 300), 800),
    ]
    context.setBlendMode(.screen)
    for (hex, centre, radius) in lights { glow(context, hex, alpha: 0.55, at: centre, radius: radius * 1.25) }
}

// Gruvbox: a dot grid that warms into a low yellow-orange sun.
draw("gruvbox") { context, random in
    fill(context, top: 0x282828, bottom: 0x1D2021)
    let sun = CGPoint(x: 1920, y: 700)
    glow(context, 0xFE8019, alpha: 0.4, at: sun, radius: 1800)
    for x in stride(from: 48, to: width, by: 96) {
        for y in stride(from: 48, to: height, by: 96) {
            let distance = hypot(CGFloat(x) - sun.x, CGFloat(y) - sun.y)
            let near = max(0, 1 - distance / 1900)
            let size = 8 + 16 * near
            context.setFillColor(near > 0.55 ? rgb(0xFABD2F, 0.5 + 0.4 * near) : near > 0.25 ? rgb(0xD65D0E, 0.35 + near) : rgb(0x504945, 0.9))
            context.fillEllipse(in: CGRect(x: CGFloat(x) - size / 2, y: CGFloat(y) - size / 2, width: size, height: size))
        }
    }
}

// Tokyo Night: a night sky with a few constellations drawn in, the app's own motif.
draw("tokyo-night") { context, random in
    fill(context, top: 0x1A1B26, bottom: 0x13141C)
    glow(context, 0xBB9AF7, alpha: 0.16, at: CGPoint(x: 1100, y: 1500), radius: 1500)
    glow(context, 0x7AA2F7, alpha: 0.14, at: CGPoint(x: 3000, y: 800), radius: 1400)
    for _ in 0..<1400 {
        let size = CGFloat.random(in: 1.5...4.5, using: &random)
        context.setFillColor(rgb([0xC0CAF5, 0xA9B1D6, 0x7DCFFF].randomElement(using: &random)!, .random(in: 0.25...0.85, using: &random)))
        context.fillEllipse(in: CGRect(x: .random(in: 0..<CGFloat(width), using: &random), y: .random(in: 0..<CGFloat(height), using: &random), width: size, height: size))
    }
    for _ in 0..<6 {
        let start = CGPoint(x: .random(in: 300...3500, using: &random), y: .random(in: 300...2100, using: &random))
        var points = [start]
        for _ in 0..<Int.random(in: 4...6, using: &random) {
            let last = points.last!
            points.append(CGPoint(x: last.x + .random(in: -260...260, using: &random), y: last.y + .random(in: -220...220, using: &random)))
        }
        context.setStrokeColor(rgb(0x7AA2F7, 0.35))
        context.setLineWidth(2.5)
        context.addLines(between: points)
        context.strokePath()
        for point in points {
            glow(context, 0xC0CAF5, alpha: 0.5, at: point, radius: 26)
            context.setFillColor(rgb(0xE0E6FF))
            context.fillEllipse(in: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10))
        }
    }
}

// Kanagawa: layered waves under a low moon, in the theme's ink and wave blues.
draw("kanagawa") { context, random in
    fill(context, top: 0x223249, bottom: 0x16161D)
    glow(context, 0xDCA561, alpha: 0.35, at: CGPoint(x: 2900, y: 1750), radius: 520)
    context.setFillColor(rgb(0xDCD7BA, 0.92))
    context.fillEllipse(in: CGRect(x: 2900 - 150, y: 1750 - 150, width: 300, height: 300))
    let bands: [UInt32] = [0x2D4F67, 0x223249, 0x1F1F28, 0x16161D]
    for index in 0..<14 {
        let along = CGFloat(index) / 13
        let parts = (0..<3).map { _ in (amplitude: CGFloat.random(in: 20...90, using: &random), length: CGFloat.random(in: 180...600, using: &random), phase: CGFloat.random(in: 0...6.28, using: &random)) }
        let line = wave(context, base: 1300 - along * 1250, parts: parts)
        let band = CGMutablePath()
        band.addPath(line)
        band.addLine(to: CGPoint(x: width + 20, y: -20))
        band.addLine(to: CGPoint(x: -20, y: -20))
        band.closeSubpath()
        context.addPath(band)
        context.setFillColor(rgb(bands[min(bands.count - 1, Int(along * CGFloat(bands.count)))], 0.55))
        context.fillPath()
        context.addPath(line)
        context.setStrokeColor(rgb(index % 3 == 0 ? 0x7E9CD8 : 0x957FB8, 0.45))
        context.setLineWidth(3)
        context.strokePath()
    }
}
