import ConstellationCore
import SwiftUI

/// An archived session's transcript from the store: your messages, the agent's replies, tool calls on
/// one line each, and the outcome. Read only, since its worktree is gone.
struct ArchivedTranscript: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let project: Project?
    let back: () -> Void
    @State private var entries: [TranscriptEntry]?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let entries {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(entries.indices, id: \.self) { index in
                            TranscriptEntryView(entry: entries[index])
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
                .defaultScrollAnchor(.bottom)
                .frame(height: 480)
            } else {
                Text("Loading transcript…").font(.ui(13)).foregroundStyle(Palette.textTertiary).padding(16)
            }
        }
        .task(id: session.id) {
            let store = model.services.store
            let id = session.id
            let events = await Task.detached { (try? store.events(for: id)) ?? [] }.value
            entries = TranscriptEntry.entries(from: events.map(\.event))
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: back) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .medium))
                    Text("Results")
                }
            }
            .buttonStyle(ConstellationButtonStyle(weight: .quiet, height: 24))
            if let project { ProjectMark(project: project) }
            Text(session.title).font(.ui(13)).foregroundStyle(Palette.text).lineLimit(1)
            Spacer(minLength: 8)
            Text("Archived · read only").font(.ui(12)).foregroundStyle(Palette.textTertiary)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }
}

enum TranscriptEntry: Hashable {
    case user(String, [Attachment])
    case assistant(String)
    case tool(String)
    case outcome(Outcome)
    case failure(String)

    static func entries(from events: [SessionEvent]) -> [TranscriptEntry] {
        events.compactMap { event in
            switch event {
            case .userMessage(let text, let attachments): .user(text, attachments ?? [])
            case .assistantText(let text, isFinal: true): .assistant(text)
            case .toolCall(let call): .tool(call.name == "Bash" ? "$ \(call.summary)" : "● \(call.name) \(call.summary)")
            case .outcome(let outcome): .outcome(outcome)
            case .failed(_, let message): .failure(message)
            default: nil
            }
        }
    }
}

private struct TranscriptEntryView: View {
    let entry: TranscriptEntry

    var body: some View {
        switch entry {
        case .user(let text, let attachments):
            VStack(alignment: .leading, spacing: 6) {
                if !attachments.isEmpty { AttachmentRow(attachments: attachments, size: 56) }
                if !text.isEmpty {
                    Text(text)
                        .font(.ui(13))
                        .foregroundStyle(Palette.text)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Palette.surfaceRaised, in: .rect(cornerRadius: 10))
                        .copyable(text, alignment: .trailing, help: "Copy message")
                }
            }
            .padding(.top, 8)
        case .assistant(let text):
            Text(Self.markdown(text))
                .font(.ui(13))
                .foregroundStyle(Palette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .copyable(text, alignment: .bottomTrailing, help: "Copy message")
        case .tool(let line):
            Text(line).font(.ui(12)).foregroundStyle(Palette.textTertiary).lineLimit(1).truncationMode(.tail)
        case .outcome(let outcome):
            Text((outcome.status == .succeeded ? "\(Glyph.done) " : "\(Glyph.failed) ") + outcome.summary)
                .font(.ui(12))
                .foregroundStyle(outcome.status == .succeeded ? Palette.text : Palette.error)
        case .failure(let message):
            Text(message).font(.ui(12)).foregroundStyle(Palette.error)
        }
    }

    private static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
