import AppKit
import ConstellationCore
import SwiftUI

extension Animation {
    /// Onboarding's shared-element spring: 0.5 s, damping 0.85.
    static let onboarding = Animation.spring(response: 0.5, dampingFraction: 0.85)
}

/// The app's own icon, as the Dock shows it.
struct AppIconMark: View {
    let size: CGFloat

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

/// Four stars and the lines between them.
struct ConstellationMark: View {
    var body: some View {
        Canvas { context, size in
            let points = [CGPoint(x: 0.18, y: 0.3), CGPoint(x: 0.5, y: 0.16), CGPoint(x: 0.82, y: 0.42), CGPoint(x: 0.42, y: 0.84)]
                .map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
            var path = Path()
            path.addLines([points[0], points[1], points[2], points[3], points[0]])
            context.stroke(path, with: .color(.white.opacity(0.75)), lineWidth: size.width * 0.04)
            for (index, point) in points.enumerated() {
                let radius = size.width * (index == 1 ? 0.11 : 0.08)
                context.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)), with: .color(.white))
            }
        }
    }
}

/// The frosted card that holds a step's choices.
struct OnboardingCard: ViewModifier {
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(hex: 0x181715, opacity: 0.74)))
            }
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.1)))
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(0.1), lineWidth: 1)
                    .mask(alignment: .top) { Rectangle().frame(height: 1) }
            }
            .shadow(color: .black.opacity(0.35), radius: 30, y: 18)
    }
}

extension View {
    func onboardingCard(padding: CGFloat = 16) -> some View {
        modifier(OnboardingCard(padding: padding))
    }

    /// A shared element between steps, unless Reduce Motion is on.
    @ViewBuilder func onboardingMatched(_ id: String, in namespace: Namespace.ID, enabled: Bool) -> some View {
        if enabled { matchedGeometryEffect(id: id, in: namespace) } else { self }
    }

    /// The amber ring on whatever the arrows have selected.
    func keyboardSelected(_ isSelected: Bool, cornerRadius: CGFloat = 12) -> some View {
        overlay {
            // The focus blue, as round a focused card on the desktop; a chosen state shows with a
            // fill or a tick instead, so the two never make a double ring.
            RoundedRectangle(cornerRadius: cornerRadius + 3, style: .continuous)
                .strokeBorder(Palette.focus.opacity(isSelected ? 1 : 0), lineWidth: 2)
                .padding(-3)
                .animation(.hover, value: isSelected)
        }
    }
}

/// "Continue →", the big cream pill.
struct ContinueButtonStyle: ButtonStyle {
    var isProminent = true

    func makeBody(configuration: Configuration) -> some View {
        ContinueButtonBody(configuration: configuration, isProminent: isProminent)
    }

    private struct ContinueButtonBody: View {
        let configuration: Configuration
        let isProminent: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(.ui(15, weight: .semibold))
                .padding(.horizontal, 20)
                .frame(height: 42)
                .foregroundStyle(isProminent ? Color(hex: 0x161513) : Palette.text)
                .background(background, in: .capsule)
                .overlay { if !isProminent { Capsule().strokeBorder(Palette.text.opacity(0.16)) } }
                .shadow(color: isProminent ? Palette.text.opacity(isHovered ? 0.28 : 0.14) : .clear, radius: 16, y: 4)
                .opacity(isEnabled ? 1 : 0.4)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .onHover { isHovered = $0 }
                .animation(.hover, value: configuration.isPressed)
                .animation(.hover, value: isHovered)
                .keyboardFocusRing(cornerRadius: 21)
        }

        private var background: Color {
            if isProminent { return configuration.isPressed || isHovered ? .white : Palette.text }
            return isHovered ? Palette.surfaceRaised.opacity(1) : Palette.surfaceRaised.opacity(0.7)
        }
    }
}

/// The round back arrow.
struct RoundIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Palette.text)
            .frame(width: 42, height: 42)
            .background(Palette.surfaceRaised.opacity(configuration.isPressed ? 1 : 0.75), in: .circle)
            .overlay(Circle().strokeBorder(Palette.text.opacity(0.14)))
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.hover, value: configuration.isPressed)
            .keyboardFocusRing(cornerRadius: 21)
    }
}

/// A small pill button inside a card, as Rex's "Install" and "Grant…".
struct PillButtonStyle: ButtonStyle {
    var tint: Color = Palette.ask

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ui(12.5, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(tint.opacity(configuration.isPressed ? 0.26 : 0.15), in: .capsule)
            .animation(.hover, value: configuration.isPressed)
            .keyboardFocusRing(cornerRadius: 13)
    }
}

/// "Recommended", "Not granted yet", "Ready".
struct StatusBadge: View {
    let text: String
    var color: Color = Palette.textTertiary
    var isFilled = false

    var body: some View {
        Text(text)
            .font(.ui(11, weight: .semibold))
            .foregroundStyle(isFilled ? Color(hex: 0x161513) : color)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(isFilled ? color : color.opacity(0.12), in: .capsule)
            .overlay { if !isFilled { Capsule().strokeBorder(color.opacity(0.35)) } }
            .contentTransition(.opacity)
    }
}

/// Six steps after Welcome, as a row of pills.
struct StepProgress: View {
    @Environment(\.onboardingInk) private var ink
    let step: OnboardingStep

    var body: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.allCases.dropFirst(), id: \.self) { item in
                Capsule()
                    .fill(item == step ? ink.primary : item < step ? ink.tertiary : ink.faint)
                    .frame(width: item == step ? 22 : 6, height: 6)
            }
        }
        .animation(.onboarding, value: step)
        .accessibilityElement()
        .accessibilityLabel("Step \(step.rawValue) of \(OnboardingStep.allCases.count - 1)")
    }
}

/// Key chips for a binding: "⌘K" becomes ⌘ and K.
struct BindingChips: View {
    let binding: KeyBinding?

    var body: some View {
        if let binding {
            KeyChips(strokes: binding.strokes)
        } else {
            Text("unbound").font(.ui(12)).foregroundStyle(Palette.textTertiary)
        }
    }
}

/// An install or sign-in, run in a small terminal tile inside the Agents card. It reports when
/// the command finishes (from the shell's OSC 133 marks), so the agent can be checked again.
struct FixTerminal: NSViewRepresentable {
    let fix: ProviderFix
    let onFinish: (Int32?) -> Void

    func makeNSView(context: Context) -> ShellTerminalView {
        let shell = ShellTerminalView()
        var sentCommand = false
        shell.onMark = { mark in
            switch mark {
            case .promptStarted where !sentCommand:
                sentCommand = true
                shell.send(text: fix.command + "\r")
            case .commandFinished(let code):
                onFinish(code)
            default:
                break
            }
        }
        shell.start(ShellLaunch(directory: .homeDirectory, secrets: [:]))
        DispatchQueue.main.async { shell.window?.makeFirstResponder(shell) }
        return shell
    }

    func updateNSView(_ shell: ShellTerminalView, context: Context) {}

    static func dismantleNSView(_ shell: ShellTerminalView, coordinator: ()) {
        shell.onMark = nil
        shell.onExit = nil
        shell.terminate()
    }
}

/// Text over onboarding's frosted wallpaper: light, solid tints of the wallpaper's own hue rather
/// than white faded, so it reads as part of the picture. Plain cream and greys without a wallpaper.
struct OnboardingInk {
    var primary = Palette.text
    var secondary = Palette.textSecondary
    var tertiary = Palette.textTertiary
    /// For marks still to come, like the progress pills ahead.
    var faint = Color(hex: 0x4A4640)

    init(hue: (hue: Double, saturation: Double)?) {
        guard let hue else { return }
        // A grey wallpaper keeps nearly neutral text; a colourful one tints it.
        let tint = min(1, hue.saturation / 0.35)
        primary = Color(hue: hue.hue, saturation: 0.07 * tint, brightness: 0.97)
        secondary = Color(hue: hue.hue, saturation: 0.2 * tint, brightness: 0.86)
        tertiary = Color(hue: hue.hue, saturation: 0.28 * tint, brightness: 0.72)
        faint = Color(hue: hue.hue, saturation: 0.35 * tint, brightness: 0.38)
    }
}

extension EnvironmentValues {
    @Entry var onboardingInk = OnboardingInk(hue: nil)
}
