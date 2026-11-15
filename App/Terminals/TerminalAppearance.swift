import AppKit
import GhosttyTerminal
import SwiftUI

/// How every terminal looks. One Ghostty controller serves them all, with a base config of our
/// own (SF Mono, a clear background that shows the tile's glass) and colours laid on top through
/// ``apply(_:)``, Constellation Dark until a theme says otherwise. Your Ghostty config is not read.
@MainActor
enum TerminalAppearance {
    static let controller: TerminalController = {
        let colors = TerminalColors.constellationDark
        let theme = TerminalTheme(light: colors.configuration, dark: colors.configuration)
        return TerminalController(configSource: .generated(base.rendered), theme: theme)
    }()

    /// Colours for every terminal, replacing the ones they have.
    static func apply(_ colors: TerminalColors) {
        let configuration = colors.configuration
        controller.setTheme(TerminalTheme(light: configuration, dark: configuration))
    }

    /// The opened view's size. Tiles show a smaller mini view.
    static let fontSize: Float = 12

    private static let base = TerminalConfiguration { builder in
        builder.withFontFamily("SF Mono")
        // Named faces: left to choose, Ghostty settles on SF Mono's italics for regular and bold text.
        builder.withCustom("font-style", "Regular")
        builder.withCustom("font-style-bold", "Bold")
        builder.withCustom("font-style-italic", "Regular Italic")
        builder.withCustom("font-style-bold-italic", "Bold Italic")
        builder.withFontSize(fontSize)
        builder.withCursorStyle(.block)
        // The tile draws its own glass; cells with a colour of their own stay opaque.
        builder.withBackgroundOpacity(0)
        builder.withCustom("macos-option-as-alt", "true")
    }
}

/// The colours a theme sets on terminals: the seam a theming pass calls through
/// ``TerminalAppearance/apply(_:)``.
struct TerminalColors: Equatable {
    var background: NSColor
    var foreground: NSColor
    /// The 16 ANSI colours: black, red, green, yellow, blue, magenta, cyan, white, then bright.
    var palette: [NSColor]
    var cursor: NSColor
    var selectionBackground: NSColor
    var selectionForeground: NSColor?

    var configuration: TerminalConfiguration {
        TerminalConfiguration { builder in
            builder.withBackground(background.ghosttyHex)
            builder.withForeground(foreground.ghosttyHex)
            for (index, color) in palette.prefix(16).enumerated() {
                builder.withPalette(index, color: color.ghosttyHex)
            }
            builder.withCursorColor(cursor.ghosttyHex)
            builder.withSelectionBackground(selectionBackground.ghosttyHex)
            if let selectionForeground { builder.withSelectionForeground(selectionForeground.ghosttyHex) }
        }
    }

    /// The canvas's warm dark palette: tile fill behind, warm off-white text, the ask amber cursor,
    /// and ANSI colours drawn from the status colours.
    static let constellationDark: TerminalColors = {
        let surface = NSColor(Palette.surface)
        let text = NSColor(Palette.text)
        let hex = { (value: UInt32) in NSColor(Color(hex: value)) }
        return TerminalColors(
            background: hex(0x1E1C1A),
            foreground: text,
            palette: [
                hex(0x2A2724), NSColor(Palette.error), NSColor(Palette.done), NSColor(Palette.ask),
                NSColor(Palette.working), hex(0xC99BBF), hex(0x7FB9AE), hex(0xD6CFC3),
                NSColor(Palette.textTertiary), hex(0xF28F89), hex(0xB9D29C), hex(0xF0C27A),
                hex(0xAAC6E8), hex(0xDDB3D8), hex(0x9CD0C5), hex(0xF7F3EC),
            ],
            cursor: NSColor(Palette.ask),
            // Ghostty takes no alpha here, so text at a quarter over the surface, mixed by hand.
            selectionBackground: surface.blended(withFraction: 0.25, of: text) ?? surface,
            selectionForeground: text
        )
    }()
}

private extension NSColor {
    /// `#RRGGBB` in sRGB, the form Ghostty's config takes.
    var ghosttyHex: String {
        let color = usingColorSpace(.sRGB) ?? self
        let channels = [color.redComponent, color.greenComponent, color.blueComponent]
            .map { Int((min(max($0, 0), 1) * 255).rounded()) }
        return "#" + channels.map { String(format: "%02X", $0) }.joined()
    }
}
