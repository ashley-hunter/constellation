import ConstellationCore
import SwiftUI

/// A note on the desktop: the shared title line with the note's first line as its name, and the
/// next few lines below as plain text. ↵, space or a click opens it.
struct NoteTile: View {
    @Environment(AppModel.self) private var model
    @Environment(\.cardSize) private var size
    let note: Terminal
    let project: Project?

    var body: some View {
        let isFocused = model.focusedItem == .terminal(note.id)
        let text = note.note ?? ""
        let preview = NoteText.preview(of: text)
        VStack(alignment: .leading, spacing: 0) {
            TerminalTitleBar(terminal: note, project: project)
            Group {
                if NoteText.title(of: text) == nil {
                    Text("Empty note").foregroundStyle(Palette.textTertiary)
                } else {
                    Text(preview).foregroundStyle(Palette.textSecondary)
                }
            }
            .font(.ui(12))
            .lineSpacing(2)
            // The session tile's summary inset.
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
        }
        .frame(width: size.width, height: size.height)
        .panelSurface(.card, edge: isFocused ? Palette.edge : .white.opacity(0.12))
        .contextMenu {
            ActionButton(.tileOpen, on: .terminal(note.id), title: "Open")
            ActionButton(.tileClose, on: .terminal(note.id), title: "Close note")
        }
    }
}

/// ↵ on a note card: the markdown in a plain editor, saved as you pause and as it closes.
struct OpenedNotePanel: View {
    @Environment(AppModel.self) private var model
    let note: Terminal
    @Environment(\.presentationIsSettled) private var isSettled

    /// The browser's size: room to write.
    static func frame(in size: CGSize) -> CGRect {
        OpenedBrowserPanel.frame(in: size)
    }

    var body: some View {
        VStack(spacing: 0) {
            NotePanelHeader(note: note)
            // Like the shell and the page, the editor joins once the panel has grown and leaves as
            // it shrinks, the text standing in for it meanwhile.
            ZStack(alignment: .topLeading) {
                if isSettled {
                    NoteEditor(note: note)
                        .id(note.id)
                        .transition(.opacity.animation(.fadeIn))
                } else {
                    Text(model.noteText(of: note.id))
                        .font(NoteEditor.font)
                        .lineSpacing(NoteEditor.lineSpacing)
                        .foregroundStyle(Palette.text)
                        // The text view's line padding.
                        .padding(.horizontal, 5)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 28)
            .padding(.top, 4)
            .padding(.bottom, 24)
            .clipped()
        }
        .panelSurface()
    }
}

private struct NotePanelHeader: View {
    @Environment(AppModel.self) private var model
    let note: Terminal

    var body: some View {
        PanelHeader {
            TerminalGlyph(state: .idle, kind: .note)
            if let project = model.project(note.projectID) { ProjectMark(project: project) }
            Text(model.displayTitle(of: note))
                .font(.ui(13, weight: .medium))
                .foregroundStyle(note.title.isEmpty ? Palette.textSecondary : Palette.text)
                .lineLimit(1)
                .truncationMode(.tail)
        } trailing: {
            PanelMaximiseButton()
            PanelOverflowMenu(help: "More: copy, send to a chat, close") {
                Button("Copy") { model.copyNote(note.id) }
                let recipients = model.noteRecipients(in: note.projectID)
                Menu("Send to chat") {
                    ForEach(recipients) { session in
                        Button(session.title) { model.sendNote(note.id, to: session.id) }
                    }
                }
                .disabled(recipients.isEmpty)
                Divider()
                ActionButton(.tileClose, on: .terminal(note.id), title: "Close note")
            }
            PanelBackButton()
        }
    }
}

/// The note's text, editable, on the panel's own surface. It takes the caret as it appears, and
/// esc still goes back, as from the composer.
private struct NoteEditor: View {
    static let font = Font.ui(14)
    static let lineSpacing: CGFloat = 4

    @Environment(AppModel.self) private var model
    let note: Terminal
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextEditor(text: $text)
            .font(Self.font)
            .lineSpacing(Self.lineSpacing)
            .foregroundStyle(Palette.text)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.automatic)
            .focused($isFocused)
            .onAppear {
                text = model.noteText(of: note.id)
                isFocused = true
            }
            .onChange(of: text) { _, text in model.editNote(note.id, text: text) }
            .onDisappear { model.commitNote(note.id) }
    }
}
