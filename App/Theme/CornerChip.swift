import SwiftUI

/// A small chip that sits on a card's corner: the panel's own surface, a hairline edge and a soft
/// two-layer shadow, so it reads as part of the card rather than a sticker on it. Centred on the
/// corner's arc, so it hugs the curve instead of covering the title.
struct CornerChip<Label: View>: View {
    var tint: Color = Palette.edge
    @ViewBuilder let label: Label

    /// Where a chip's centre sits from the card's corner: just outside the arc of its 20pt radius, so
    /// it hugs the curve without covering the icon or dot on the title line.
    static var arcInset: CGFloat { PanelSurface.cornerRadius * (1 - 1 / 2.squareRoot()) - 4 }

    var body: some View {
        label
            .font(.ui(11, weight: .semibold)).monospacedDigit()
            .padding(.horizontal, 6)
            .frame(minWidth: 20, minHeight: 20)
            .background(Palette.popover, in: .rect(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(tint, lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
            .shadow(color: .black.opacity(0.25), radius: 6, y: 4)
    }
}
