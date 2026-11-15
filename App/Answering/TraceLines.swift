import ConstellationCore
import SwiftUI

/// One of your messages in a transcript, as Sort's bubble: a small raised card on the right with
/// a faint top sheen, a 1 pt inner edge and a tiny shadow.
struct MessageBubble: View {
    let text: String
    /// Who it was sent to: the bubble takes a soft tint of that agent's colour.
    var provider: Provider = .claudeCode

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        Text(text)
            .font(.ui(14))
            .lineSpacing(4)
            .foregroundStyle(Palette.text)
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                shape.fill(Palette.card)
                    .overlay(shape.fill(Palette.provider(provider).opacity(0.16)))
                    .overlay(shape.fill(LinearGradient(colors: [.white.opacity(0.05), .clear], startPoint: .top, endPoint: .bottom)))
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
                    .shadow(color: .black.opacity(0.15), radius: 1.5, y: 2)
            }
            .overlay(shape.strokeBorder(Palette.provider(provider).opacity(0.3), lineWidth: 1))
            .frame(maxWidth: 320, alignment: .trailing)
    }
}

/// A run of tool calls as Sort's trace: a line per call, "Searched for minimumReleaseAge", each
/// opening onto its output. Once something follows them, or past three, they fold under one line
/// saying what they did ("Ran 2 commands, read 1 file") until opened, and how many failed so an
/// error inside isn't hidden. Constellation's own MCP calls are left out.
struct ToolTrace: View {
    let steps: [Transcript.ToolStep]
    /// A reply or another message follows, so the steps are history.
    var isSettled = false
    @State private var isExpanded = false

    var body: some View {
        let shown = steps.filter { $0.call.phrase != nil }
        if shown.count > 3 || (isSettled && shown.count > 1) {
            let kinds = shown.compactMap(\.call.phrase?.kind)
            let common = Dictionary(grouping: kinds) { $0 }.max { $0.value.count < $1.value.count }?.key ?? .other
            VStack(alignment: .leading, spacing: 0) {
                Button { withAnimation(.hover) { isExpanded.toggle() } } label: {
                    TraceRow(systemImage: TraceLine.symbol(for: common), isError: false, isExpanded: isExpanded) { _ in
                        let failed = shown.count { $0.result?.isError == true }
                        let note = Text(failed == 0 ? "" : " · \(failed) failed").foregroundStyle(Palette.error)
                        Text("\(ToolCall.summary(of: kinds))\(note)")
                    }
                }
                .buttonStyle(.plain)
                if isExpanded {
                    TraceIndent { lines(shown) }
                        .transition(.opacity)
                }
            }
        } else {
            lines(shown)
        }
    }

    private func lines(_ shown: [Transcript.ToolStep]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, step in
                TraceLine(step: step)
            }
        }
    }
}

/// One call: an icon by kind, the verb muted and what it acted on in full text, and a chevron
/// when there's output to open.
private struct TraceLine: View {
    let step: Transcript.ToolStep
    @State private var isExpanded = false

    var body: some View {
        if let phrase = step.call.phrase {
            let output = step.result.map { LiveOutput.redacted($0.summary).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    guard !output.isEmpty else { return }
                    withAnimation(.hover) { isExpanded.toggle() }
                } label: {
                    TraceRow(
                        systemImage: Self.symbol(for: phrase.kind),
                        isError: step.result?.isError == true,
                        isExpanded: output.isEmpty ? nil : isExpanded
                    ) { isHovered in
                        let object = Text(phrase.object.isEmpty ? "" : " \(phrase.object)")
                            .foregroundStyle(step.result?.isError == true ? Palette.error : Palette.text)
                        Text("\(step.result == nil ? phrase.present : phrase.past)\(object)")
                    }
                }
                .buttonStyle(.plain)
                if isExpanded {
                    TraceIndent {
                        Text(output)
                            .font(.mono(12))
                            .lineSpacing(4)
                            .foregroundStyle(step.result?.isError == true ? Palette.error : Palette.textSecondary)
                            .lineLimit(16)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .transition(.opacity)
                }
            }
        }
    }

    static func symbol(for kind: ToolCall.Phrase.Kind) -> String {
        switch kind {
        case .search: "magnifyingglass"
        case .read: "doc.text"
        case .edit: "pencil"
        case .command: "terminal"
        case .web: "globe"
        case .other: "wrench"
        }
    }
}

/// A trace line's frame: a 16 pt icon, the title on one line, and a chevron at 40% that turns down
/// when open. Muted until hovered; the error colour on failure.
private struct TraceRow<Title: View>: View {
    var systemImage: String?
    let isError: Bool
    /// Nil when there's nothing to open, so no chevron.
    let isExpanded: Bool?
    @ViewBuilder let title: (Bool) -> Title
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 12))
                    .frame(width: 16, height: 16)
            }
            title(isHovered)
                .lineLimit(1)
                .truncationMode(.tail)
            if let isExpanded {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .opacity(isHovered || isError ? 1 : 0.4)
                    .frame(width: 16, height: 16)
                    .padding(.leading, -4)
            }
        }
        .font(.ui(13))
        .foregroundStyle(isError ? Palette.error : isHovered ? Palette.text : Palette.textSecondary)
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .animation(.hover, value: isHovered)
    }
}

/// What a trace line opens onto, indented under its icon behind a 1 pt rule.
private struct TraceIndent<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.leading, 16)
            .padding(.trailing, 4)
            .overlay(alignment: .leading) { Rectangle().fill(Palette.edge).frame(width: 1) }
            .padding(.leading, 7)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }
}
