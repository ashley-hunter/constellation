import ConstellationCore
import SwiftUI

/// A quiet control on a panel: an optional swatch or icon, a title and, for a menu, a chevron. No
/// border or fill until hovered, so a row of them reads as text rather than a wall of pills.
struct QuietChip: View {
    let title: String
    var systemImage: String?
    var swatch: ProjectSwatch?
    var isMenu = true
    var isOn = false
    var isProminent = false
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 5) {
            if let swatch { SwatchMark(swatch: swatch) }
            if let systemImage { Image(systemName: systemImage).font(.system(size: 11, weight: .medium)) }
            Text(title).font(.ui(12, weight: isProminent ? .medium : .regular)).lineLimit(1)
            if isMenu {
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(Palette.textTertiary)
            }
        }
        .foregroundStyle(isOn ? Palette.ask : isProminent ? Palette.text : Palette.textSecondary)
        .padding(.horizontal, 7)
        .frame(height: 26)
        .background(isHovered ? Palette.text.opacity(0.07) : .clear, in: .rect(cornerRadius: Radius.control))
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .animation(.hover, value: isHovered)
    }
}
