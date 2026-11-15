import ConstellationCore
import SwiftUI

/// The row under a message while the pointer is on it, on the message's own side so it plainly
/// belongs to it: Copy, and on your messages with a checkpoint Rewind to here and Fork from here
/// (also in the context menu). The row keeps its space, so nothing moves as it shows.
struct MessageActions: ViewModifier {
    @Environment(AppModel.self) private var model
    let session: Session
    let transcript: Transcript
    let entry: Transcript.Entry
    @State private var isHovered = false

    func body(content: Content) -> some View {
        switch entry {
        case .user(_, let text, _):
            let branches = canBranch
            row(content, text: text, isMine: true, branches: branches)
                .contextMenu {
                    if branches {
                        Button("Rewind to Here…") { rewind() }
                        Button("Fork from Here") { fork() }
                    }
                }
        case .assistant(_, let text):
            row(content, text: text, isMine: false, branches: false)
        default:
            content
        }
    }

    private var canBranch: Bool {
        guard let index = transcript.messageIndex(ofEntry: entry.id), model.canBranch(session) else { return false }
        return transcript.rewindCut(toMessage: index, provider: session.provider) != nil
    }

    private func row(_ content: Content, text: String, isMine: Bool, branches: Bool) -> some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 2) {
            content
            HStack(spacing: 2) {
                if !text.isEmpty { CopyButton(text: text, help: isMine ? "Copy your message" : "Copy the reply") }
                if branches {
                    action("Rewind to here", systemImage: "arrow.uturn.backward") { rewind() }
                    action("Fork from here", systemImage: "arrow.triangle.branch") { fork() }
                }
            }
            .padding(.horizontal, isMine ? 0 : -6)
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
        }
        .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .animation(.hover, value: isHovered)
    }

    private func action(_ title: String, systemImage: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(IconButtonStyle(width: 24, height: 24))
        .help(title)
    }

    private func rewind() {
        model.requestRewind(session, transcript: transcript, entryID: entry.id)
    }

    private func fork() {
        model.fork(session, transcript: transcript, entryID: entry.id)
    }
}

/// Confirms Rewind to here, listing what it loses: later messages, and optionally file changes and commits.
struct RewindConfirmation: View {
    @Environment(AppModel.self) private var model
    let request: RewindRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rewind to this message?").font(.ui(15, weight: .semibold))
            Text(conversationLine)
                .font(.ui(13))
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            files
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { model.rewindRequest = nil }
                    .buttonStyle(.quiet)
                    .keyboardShortcut(.cancelAction)
                Button("Rewind") { model.confirmRewind() }
                    .buttonStyle(.primary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .panelSurface()
    }

    private var conversationLine: String {
        let count = request.messagesLost
        let messages = count == 1 ? "This message and its reply" : "This message and the \(count - 1) after it, with their replies,"
        return "\(messages) leave the conversation. Your message goes back into the composer to edit and send again."
    }

    @ViewBuilder private var files: some View {
        if request.commit == nil {
            Text("Files can't be reverted: no snapshot was taken when this message was sent.")
                .font(.ui(12))
                .foregroundStyle(Palette.textTertiary)
        } else if let error = request.lossError {
            Text("Files can't be reverted: \(error)").font(.ui(12)).foregroundStyle(Palette.error)
        } else if let loss = request.loss {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: Binding(
                    get: { model.rewindRequest?.revertsFiles ?? false },
                    set: { model.rewindRequest?.revertsFiles = $0 }
                )) {
                    Text(loss.isEmpty ? "Revert files too (nothing has changed since)" : "Also revert the files to how they were")
                        .font(.ui(13))
                }
                .toggleStyle(.checkbox)
                .disabled(loss.isEmpty)
                if !loss.isEmpty, request.revertsFiles {
                    VStack(alignment: .leading, spacing: 2) {
                        if loss.commits > 0 {
                            Text("\(loss.commits) \(loss.commits == 1 ? "commit" : "commits") made since will be undone")
                                .foregroundStyle(Palette.ask)
                        }
                        ForEach(loss.files.prefix(12), id: \.self) { Text($0) }
                        if loss.files.count > 12 { Text("and \(loss.files.count - 12) more") }
                    }
                    .font(.ui(12))
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
            }
        } else {
            Text("Checking what changed since…").font(.ui(12)).foregroundStyle(Palette.textTertiary)
        }
    }
}
