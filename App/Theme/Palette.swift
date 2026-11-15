import ConstellationCore
import SwiftUI

/// The canvas's dark warm palette.
enum Palette {
    static let surface = Color(hex: 0x1C1A18)
    static let surfaceRaised = Color(hex: 0x262421)
    static let surfaceSunken = Color(hex: 0x12110F)

    static let text = Color(hex: 0xEFE9DE)
    static let textSecondary = Color(hex: 0xAAA398)
    static let textTertiary = Color(hex: 0x8A847A)
    static let icon = Color(hex: 0xC9C3B8)

    static let ask = Color(hex: 0xE5A94F)
    /// Where the keyboard is: the focus ring and the ⌘ numbers. Brighter than `working`, and never
    /// amber, which means a card needs you.
    static let focus = Color(hex: 0x6FA8FF)
    static let error = Color(hex: 0xEB716B)
    static let working = Color(hex: 0x8FB0D8)
    static let done = Color(hex: 0xA3BE84)

    static let tileFill = Color(hex: 0x1E1C1A).opacity(0.86)
    static let hairline = Color.white.opacity(0.08)
    static let rowHover = Color.white.opacity(0.06)
    static let rowSelected = Color.white.opacity(0.12)
    /// The keyboard's row in a list (the launcher, the palette, completions): the focus blue, as on
    /// a focused card, so blue always means the keys are here.
    static let rowCursor = focus.opacity(0.18)
    static let labelBackground = Color(hex: 0x12110F).opacity(0.88)

    /// Sort UI's popover: the fill of panels, sheets and the pill composer.
    static let popover = Color(hex: 0x1E1D1B)
    /// A raised card on a panel, e.g. your messages in the transcript.
    static let card = Color(hex: 0x262421)
    /// The composer: Sort's popover, a step up from the panel it sits on.
    static let composer = Color(hex: 0x2A2825)
    /// The 1 pt edge drawn just outside panels, cards and the composer.
    static let edge = text.opacity(0.1)

    /// Each agent's own colour: Claude's coral, and the teal-green OpenAI uses for Codex.
    static func provider(_ provider: Provider) -> Color {
        switch provider {
        case .claudeCode: Color(hex: 0xD97757)
        case .codex: Color(hex: 0x10A37F)
        }
    }

    static func swatch(_ swatch: ProjectSwatch) -> Color {
        Color(hex: UInt32(swatch.hex.dropFirst(), radix: 16) ?? 0x8E979F)
    }

    /// The swatch's hue, more saturated and a little brighter, for the glassy project dot.
    static func vivid(_ swatch: ProjectSwatch) -> Color {
        let base = NSColor(self.swatch(swatch)).usingColorSpace(.sRGB) ?? .gray
        var (hue, saturation, brightness, alpha): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        base.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return Color(nsColor: NSColor(hue: hue, saturation: min(1, saturation * 1.45 + 0.12), brightness: min(1, brightness * 1.08 + 0.06), alpha: alpha))
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
