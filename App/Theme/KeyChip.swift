import ConstellationCore
import SwiftUI

/// A keycap: a soft translucent chip that sits quietly on the glass panels.
struct KeyChip: View {
    let key: String
    var font: Font = .ui(11, weight: .medium)

    init(_ key: String, font: Font = .ui(11, weight: .medium)) {
        self.key = key
        self.font = font
    }

    var body: some View {
        Text(key)
            .font(font)
            .foregroundStyle(Palette.textSecondary)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(Palette.text.opacity(0.07), in: .rect(cornerRadius: Radius.key))
            .overlay(RoundedRectangle(cornerRadius: Radius.key).strokeBorder(Palette.text.opacity(0.08), lineWidth: 0.5))
    }
}

/// A key chip followed by what it does, for tile footers.
extension EnvironmentValues {
    /// The card has the keyboard, so its keys are worth showing; on any other card they stay hidden
    /// until the pointer is on them, as they'd act on the focused card instead.
    @Entry var showsCardKeys = true
    /// The size a card lays itself out at: full size, or bigger when its frame is, so a big card
    /// shows more rather than magnified text.
    @Entry var cardSize = CGSize(width: TileMetrics.fullSize.width, height: TileMetrics.fullSize.height)
}

struct KeyHint: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            KeyChip(key)
            Text(label).font(.ui(12)).foregroundStyle(Palette.textSecondary)
        }
    }
}

/// A key sequence as chips: one per modifier, then the key, uppercase after a modifier as the
/// menus show it, and tab spelled out.
struct KeyChips: View {
    let strokes: [KeyStroke]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(Self.caps(for: strokes).enumerated()), id: \.offset) { _, cap in KeyChip(cap) }
        }
    }

    static func caps(for strokes: [KeyStroke]) -> [String] {
        strokes.flatMap { stroke -> [String] in
            let modifiers = KeyStroke(key: "", modifiers: stroke.modifiers).label.map(String.init)
            var key = KeyStroke(key: stroke.key).label
            if key == "⇥" { key = "tab" }
            return modifiers + [modifiers.isEmpty || key.count > 1 ? key : key.uppercased()]
        }
    }
}
