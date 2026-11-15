import ConstellationCore
import SwiftUI

/// Answer in place. A waiting tile shows its answers in a warm band along its bottom, focused or
/// not, under its question, which wraps into whatever room the band leaves: the first two at
/// rest, all of them with their keys once it's focused. A focused
/// failed tile turns into its failure and Retry below its title bar. Anything that needs reading
/// points to the chat view.
struct InPlaceAnswer: View {
    @Environment(AppModel.self) private var model
    let session: Session

    static func shows(for session: Session) -> Bool {
        switch session.runState {
        case .blocked: session.nextAsk != nil
        case .failed: true
        default: false
        }
    }

    @Environment(\.showsCardKeys) private var showsKeys

    var body: some View {
        if case .blocked = session.runState, let ask = session.nextAsk {
            band(for: ask)
        } else {
            turnedOver
        }
    }

    private func band(for ask: Ask) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            AskQuestion(kind: ask.kind)
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            answerBand(for: ask)
                // The answers get their room first; the question has the rest.
                .layoutPriority(1)
        }
    }

    private func answerBand(for ask: Ask) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            answers(for: ask)
        }
        .padding(.leading, 12)
        .padding(.trailing, TileAction.cornerInset)
        .padding(.top, 9)
        .padding(.bottom, TileAction.cornerInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Warming from the card's own surface into amber at the bottom edge, with no line between.
        .padding(.top, 14)
        .background {
            LinearGradient(
                stops: [
                    .init(color: Palette.card.opacity(0), location: 0),
                    .init(color: Palette.card.mix(with: Palette.ask, by: 0.06), location: 0.3),
                    .init(color: Palette.card.mix(with: Palette.ask, by: 0.2), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
        }
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: PanelSurface.cornerRadius, bottomTrailingRadius: PanelSurface.cornerRadius, style: .continuous))
        .contentShape(.rect)
        .transition(.opacity)
    }

    private var turnedOver: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(headline)
                .font(.ui(12))
                .foregroundStyle(tint)
                .lineLimit(1)
            Spacer(minLength: 0)
            // Actions sit where the tile's footer pill does, at the bottom of the card.
            if case .failed = session.runState {
                failed
            } else if let ask = session.nextAsk {
                answers(for: ask)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, TileAction.cornerInset)
        .padding(.top, 10)
        .padding(.bottom, TileAction.cornerInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The card's own surface, so it reads as the tile turning over rather than a panel on top.
        .background(Palette.card)
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: PanelSurface.cornerRadius, bottomTrailingRadius: PanelSurface.cornerRadius, style: .continuous))
        .contentShape(.rect)
        .transition(.opacity)
    }

    private var tint: Color {
        if case .failed = session.runState { return Palette.error }
        return Palette.ask
    }

    private var headline: String {
        if case .failed = session.runState { return session.failureMessage ?? "Failed" }
        return session.nextAsk?.kind.headline ?? ""
    }

    @ViewBuilder private func answers(for ask: Ask) -> some View {
        switch ask.kind {
        case .permission, .question where !ask.choices.isEmpty:
            CompactChoices(ask: ask, limit: showsKeys ? 4 : 2)
        case .secret(let secret):
            InPlaceSecret(ask: ask, secret: secret)
        case .question:
            KeyHint(key: "↵", label: "answer")
        }
    }

    private var failed: some View {
        HStack(spacing: 8) {
            TileAction(title: "Retry", systemImage: "arrow.clockwise", key: "⌘R") {
                model.perform(.sessionRetry, on: .session(session.id))
            }
            Spacer(minLength: 0)
            KeyHint(key: "↵", label: "open")
        }
    }
}

/// What a waiting card asks, in the room it has, cut short with an ellipsis when it runs out; the
/// tooltip has all of it. A command reads in monospace, as it would run.
private struct AskQuestion: View {
    let kind: AskKind

    var body: some View {
        text
            .foregroundStyle(Palette.ask)
            .help(kind.headline)
    }

    private var text: Text {
        if case .permission(let ask) = kind, Self.shellTools.contains(ask.toolName) {
            return Text("Run ").font(.ui(13)) + Text(ask.summary).font(.mono(12)) + Text("?").font(.ui(13))
        }
        return Text(kind.headline).font(.ui(13))
    }

    /// Claude Code's and Codex's names for running a command.
    private static let shellTools: Set<String> = ["Bash", "shell"]
}

/// Up to four answers in two columns, then a row for the rest when a question has more options.
private struct CompactChoices: View {
    @Environment(AppModel.self) private var model
    @Environment(\.showsCardKeys) private var showsKeys
    let ask: Ask
    var limit = 4

    var body: some View {
        let choices = Array(ask.choices.prefix(limit))
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(choices) { choice in
                Button { model.answer(ask: ask, with: choice.answer) } label: {
                    HStack(spacing: 6) {
                        Text(choice.shortLabel).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 0)
                        if showsKeys { KeyChip("⌥" + choice.key.uppercased()) }
                    }
                }
                .buttonStyle(CompactChoiceStyle(weight: choice.weight))
            }
        }
        if showsKeys { KeyHint(key: "↵", label: ask.choices.count > 4 ? "\(ask.choices.count - 4) more" : "open") }
    }
}

/// A full-width button for a tile's answer grid. Smaller than the canvas buttons so four fit.
private struct CompactChoiceStyle: ButtonStyle {
    let weight: ConstellationButtonStyle.Weight

    func makeBody(configuration: Configuration) -> some View {
        // The footer pill's quiet style: a soft fill, no border, the default answer a step brighter.
        configuration.label
            .font(.ui(12, weight: .medium))
            .foregroundStyle(weight == .primary ? Palette.text : Palette.textSecondary)
            .padding(.leading, 10)
            .padding(.trailing, 4)
            .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)
            .background(Palette.text.opacity(weight == .primary ? 0.14 : 0.07), in: .capsule)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .keyboardFocusRing(cornerRadius: 12)
    }
}

/// A masked field right on the tile, for when you have the value to hand.
private struct InPlaceSecret: View {
    @Environment(AppModel.self) private var model
    let ask: Ask
    let secret: SecretAsk
    @State private var value = ""

    var body: some View {
        HStack(spacing: 8) {
            SecureField(secret.name, text: $value)
                .textFieldStyle(.plain)
                .font(.ui(12))
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(Palette.surfaceSunken, in: .rect(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.text.opacity(0.14)))
                .onSubmit(provide)
            Button("Provide", action: provide)
                .buttonStyle(ConstellationButtonStyle(weight: .primary, height: 24))
                .disabled(value.isEmpty)
        }
        KeyHint(key: "↵", label: "more")
    }

    private func provide() {
        guard !value.isEmpty else { return }
        model.answer(ask: ask, with: .secret(value: value, saveForProject: false))
        value = ""
    }
}
