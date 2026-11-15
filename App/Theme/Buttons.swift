import SwiftUI

/// The canvas's three button weights.
struct ConstellationButtonStyle: ButtonStyle {
    enum Weight { case primary, secondary, quiet }

    var weight: Weight = .secondary
    var height: CGFloat = 28
    /// A quiet button's text colour in place of the usual grey, to match what it sits on.
    var tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ui(13, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: height)
            .foregroundStyle(foreground)
            .background(background(pressed: configuration.isPressed), in: .rect(cornerRadius: 8))
            .overlay {
                if weight == .secondary {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.text.opacity(0.14))
                }
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.hover, value: configuration.isPressed)
            .keyboardFocusRing(cornerRadius: 8)
    }

    private var foreground: Color {
        switch weight {
        case .primary: Color(hex: 0x161513)
        case .secondary: Palette.text
        case .quiet: tint ?? Palette.textSecondary
        }
    }

    private func background(pressed: Bool) -> Color {
        switch weight {
        case .primary: pressed ? .white : Palette.text
        case .secondary: Palette.surfaceRaised
        case .quiet: .clear
        }
    }
}

extension ButtonStyle where Self == ConstellationButtonStyle {
    static var primary: ConstellationButtonStyle { ConstellationButtonStyle(weight: .primary) }
    static var secondary: ConstellationButtonStyle { ConstellationButtonStyle(weight: .secondary) }
    static var quiet: ConstellationButtonStyle { ConstellationButtonStyle(weight: .quiet) }
}

/// A full-width sidebar row that highlights on hover and when selected.
struct SidebarRowStyle: ButtonStyle {
    var isSelected = false

    func makeBody(configuration: Configuration) -> some View {
        HoverRow(isSelected: isSelected) { configuration.label }
    }

    private struct HoverRow<Label: View>: View {
        let isSelected: Bool
        @ViewBuilder let label: Label
        @State private var isHovered = false

        var body: some View {
            HStack(spacing: 8) { label }
                .font(.ui(13))
                .foregroundStyle(Palette.text)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                .background(fill, in: .rect(cornerRadius: Radius.control))
                .contentShape(.rect)
                .onHover { isHovered = $0 }
                .animation(.hover, value: isHovered)
        }

        private var fill: Color {
            isSelected ? Palette.rowSelected : isHovered ? Palette.rowHover : .clear
        }
    }
}

/// An icon-only button: muted until hovered, when the icon brightens and a soft fill comes up as
/// on a quiet text button, and pressed a touch deeper. `isOn` holds it lit, for a toggle that's on;
/// `isRaised` sits it on a raised fill with an edge, as over a message.
struct IconButtonStyle: ButtonStyle {
    /// Nil lets the label set it, for one that grows, as Copy does to say Copied.
    var width: CGFloat? = 28
    var height: CGFloat = 26
    var isOn = false
    var isRaised = false

    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, style: self)
    }
}

private struct IconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let style: IconButtonStyle
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        let isLit = isHovered && isEnabled
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        configuration.label
            .foregroundStyle(!isEnabled ? Palette.textTertiary : isLit || style.isOn ? Palette.text : Palette.textSecondary)
            .frame(width: style.width, height: style.height)
            .background {
                ZStack {
                    if style.isRaised { shape.fill(Palette.surfaceRaised) }
                    shape.fill(Palette.text.opacity(configuration.isPressed ? 0.12 : isLit ? 0.07 : style.isOn ? 0.08 : 0))
                }
            }
            .overlay {
                if style.isRaised { shape.strokeBorder(Palette.text.opacity(isLit ? 0.18 : 0.1)) }
            }
            .contentShape(.rect)
            .onHover { isHovered = $0 }
            .animation(.hover, value: isLit)
            .animation(.hover, value: configuration.isPressed)
            .keyboardFocusRing(cornerRadius: Radius.control)
    }
}

/// The keyboard's ring round a control reached with Tab (Full Keyboard Access on): 2pt of the focus
/// blue just outside it, as round a focused card, in place of the system's. Nothing with the mouse.
struct KeyboardFocusRing: ViewModifier {
    var cornerRadius: CGFloat
    @Environment(\.isFocused) private var isFocused

    func body(content: Content) -> some View {
        content
            .focusEffectDisabled()
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius + 3, style: .continuous)
                    .strokeBorder(Palette.focus, lineWidth: 2)
                    .padding(-3)
                    .opacity(isFocused ? 1 : 0)
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    func keyboardFocusRing(cornerRadius: CGFloat) -> some View {
        modifier(KeyboardFocusRing(cornerRadius: cornerRadius))
    }
}
