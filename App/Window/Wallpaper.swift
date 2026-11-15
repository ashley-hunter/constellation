import AppKit
import ImageIO
import SwiftUI

/// Whether text drawn straight on the wallpaper should be light or dark.
enum WallpaperTone: Sendable {
    case dark, light

    /// Rec. 709 relative luminance above this reads as a light wallpaper.
    static let threshold = 0.55

    init(luminance: Double) {
        self = luminance > Self.threshold ? .light : .dark
    }

    var primaryText: Color { self == .dark ? Palette.text : Color(hex: 0x1C1A18) }
    var secondaryText: Color { self == .dark ? Palette.textSecondary : Color(hex: 0x3A3631) }
}

extension EnvironmentValues {
    @Entry var wallpaperTone: WallpaperTone = .dark
}

/// The main display's wallpaper: its average luminance and a screen-sized copy for the fallback backdrop.
/// Reading the file can block on a privacy prompt (a wallpaper in ~/Downloads, say), so it is never
/// read on the main actor.
struct Wallpaper: Sendable {
    var url: URL?
    var luminance: Double?
    var image: CGImage?
    /// Its average colour's hue and saturation, 0...1, for text tinted to sit on it.
    var hue: (hue: Double, saturation: Double)?

    var tone: WallpaperTone { luminance.map(WallpaperTone.init) ?? .dark }

    @MainActor
    static func url(for screen: NSScreen?) -> URL? {
        screen.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
    }

    static func load(_ url: URL, maxPixelSize: Int) async -> Wallpaper {
        await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return Wallpaper(url: url) }
            let image = thumbnail(source, maxPixelSize: maxPixelSize)
            let small = thumbnail(source, maxPixelSize: 32)
            return Wallpaper(url: url, luminance: small.flatMap(averageLuminance), image: image, hue: small.flatMap(averageHue))
        }.value
    }

    private static func thumbnail(_ source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary)
    }

    /// The hue and saturation of the average colour.
    static func averageHue(of image: CGImage) -> (hue: Double, saturation: Double)? {
        guard let average = averageColour(of: image) else { return nil }
        let colour = NSColor(srgbRed: average.red, green: average.green, blue: average.blue, alpha: 1)
        return (colour.hueComponent, colour.saturationComponent)
    }

    private static func averageColour(of image: CGImage) -> (red: Double, green: Double, blue: Double)? {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let context else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        return (Double(data[0]) / 255, Double(data[1]) / 255, Double(data[2]) / 255)
    }

    /// Rec. 709 relative luminance, averaged over every pixel.
    static func averageLuminance(of image: CGImage) -> Double? {
        let (width, height) = (image.width, image.height)
        guard width * height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var total = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            total += 0.2126 * Double(pixels[index]) + 0.7152 * Double(pixels[index + 1]) + 0.0722 * Double(pixels[index + 2])
        }
        return total / Double(width * height) / 255
    }
}

/// The wallpaper drawn behind the tiles, for when the real desktop can't show through.
struct WallpaperBackdrop: View {
    let image: CGImage?

    var body: some View {
        if let image, let screen = NSScreen.screens.first {
            // Filled to the whole screen and placed where macOS draws it, so it lines up with the
            // real desktop. The window only covers the visible frame, so the part behind the menu
            // bar (often a darker sky) is cropped off rather than squeezed in below it.
            let (full, visible) = (screen.frame, screen.visibleFrame)
            Color.clear
                .overlay(alignment: .topLeading) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: full.width, height: full.height)
                        .clipped()
                        .offset(x: full.minX - visible.minX, y: visible.maxY - full.maxY)
                }
                .clipped()
                .ignoresSafeArea()
        } else {
            Color(hex: 0x141311).ignoresSafeArea()
        }
    }
}
