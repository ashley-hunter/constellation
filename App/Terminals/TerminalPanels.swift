import AppKit
import ConstellationCore
import SwiftUI

/// ↵ on a terminal tile: the same shell, larger and taking the keyboard. Esc or a click outside
/// returns to the desktop; send a literal escape to the shell with ⌃[.
struct OpenedTerminalPanel: View {
    @Environment(AppModel.self) private var model
    let terminal: Terminal
    @Environment(\.presentationIsSettled) private var isSettled

    /// Where the panel sits in a container of `size`, centred and from layout alone, so it can grow
    /// out of its tile.
    static func frame(in size: CGSize) -> CGRect {
        let width = min(820, size.width - 64)
        let height = min(520, size.height - 80)
        return CGRect(x: ((size.width - width) / 2).rounded(), y: ((size.height - height) / 2).rounded(), width: max(width, 0), height: max(height, 0))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TerminalPanelHeader(terminal: terminal)
            // The shell is a Metal view that can't scale with the panel, so it joins once the panel
            // has grown, sized once, and leaves as it starts to shrink.
            ZStack {
                if isSettled {
                    TerminalSurface(terminalID: terminal.id, fontSize: 12, takesFocus: true)
                        .id(terminal.id)
                        .transition(.opacity.animation(.fadeIn))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The chat transcript's inset; the header above already leaves room at the top.
            .padding(.horizontal, 24)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .panelSurface()
    }
}

/// The opened terminal's ``PanelHeader``, in the session view's language: glyph, swatch, title and
/// folder on the left, and its state, a … menu and Back on the right.
private struct TerminalPanelHeader: View {
    @Environment(AppModel.self) private var model
    let terminal: Terminal

    var body: some View {
        let folder = terminal.workingDirectory
        PanelHeader {
            TerminalGlyph(state: terminal.state, kind: terminal.kind)
            if let project = model.project(terminal.projectID) { ProjectMark(project: project) }
            Text(model.displayTitle(of: terminal))
                .font(.ui(13, weight: .medium))
                .foregroundStyle(Palette.text)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(DisplayPath.abbreviated(folder))
                .font(.ui(12))
                .foregroundStyle(Palette.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(-1)
                .help(folder.path(percentEncoded: false))
        } trailing: {
            let phase = model.taskPhase(of: terminal)
            if let label = TerminalStateStyle.label(for: terminal, phase: phase) {
                Text(label)
                    .font(.ui(12))
                    .foregroundStyle(TerminalStateStyle.quietColor(for: terminal, phase: phase))
                    .padding(.trailing, 6)
            }
            if let phase { TaskButton(task: terminal, phase: phase) }
            PanelMaximiseButton()
            PanelOverflowMenu(help: "More: editor, Finder, copy path, close") {
                Button("Open in \(model.settings.preferredEditor.title)") { model.openFolder(folder) }
                Menu("Open in") {
                    ForEach(Editor.installed) { editor in
                        Button { model.openFolder(folder, in: editor) } label: {
                            Label { Text(editor.title) } icon: { Image(nsImage: editor.icon) }
                        }
                    }
                }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                Button("Copy path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(folder.path(percentEncoded: false), forType: .string)
                }
                Divider()
                ActionButton(.tileClose, on: .terminal(terminal.id), title: "Close terminal")
            }
            PanelBackButton(key: "⌘M")
        }
    }
}

/// The session view's Terminal pane: a shell in the session's worktree. It shows the session's
/// own terminals, the ones stacked behind its tile, opening one when it has none, and picks
/// between them when it has several.
struct SessionTerminalPane: View {
    @Environment(AppModel.self) private var model
    let sessionID: UUID

    var body: some View {
        let owned = model.terminals(ownedBy: sessionID)
        let shown = owned.first { $0.id == model.sessionPaneTerminalID } ?? owned.first
        VStack(spacing: 0) {
            if owned.count > 1 {
                HStack(spacing: 4) {
                    ForEach(Array(owned.enumerated()), id: \.element.id) { index, terminal in
                        Button {
                            model.sessionPaneTerminalID = terminal.id
                        } label: {
                            HStack(spacing: 6) {
                                TerminalGlyph(state: terminal.state, kind: terminal.kind)
                                Text(model.displayTitle(of: terminal))
                            }
                            .font(.ui(12))
                            .foregroundStyle(terminal.id == shown?.id ? Palette.text : Palette.textTertiary)
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                            .background(terminal.id == shown?.id ? Palette.surfaceRaised : .clear, in: .rect(cornerRadius: 6))
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
            if let shown {
                TerminalSurface(terminalID: shown.id, fontSize: 12, takesFocus: true)
                    .id(shown.id)
                    .padding(16)
            } else {
                Text("No worktree to open a shell in.")
                    .font(.ui(12))
                    .foregroundStyle(Palette.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: sessionID) {
            if model.terminals(ownedBy: sessionID).isEmpty { _ = model.paneTerminal(forSession: sessionID) }
        }
    }
}
