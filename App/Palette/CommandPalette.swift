import ConstellationCore
import SwiftUI

/// ⌘K: one field over ranked sections, the focused session's actions, sessions and projects,
/// commands and transcript matches. `>` keeps commands, `@` sessions, `/` slash commands.
/// ↵ runs the row, ⌘↵ runs it and stays, esc closes. An archived session opens read-only here.
struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    @State private var text: String
    @State private var stored: [UUID: Session] = [:]
    @State private var hits: [SearchResult] = []
    @State private var selection: String?
    @State private var archived: Session?
    /// The Add project flow, when the palette is in it.
    @State private var flow: ProjectFlow?
    @FocusState private var isFieldFocused: Bool

    init(text: String, flow: ProjectFlow? = nil) {
        _text = State(initialValue: text)
        _flow = State(initialValue: flow)
    }

    var body: some View {
        let sections = content.sections
        let rows = sections.flatMap(\.rows)
        VStack(alignment: .leading, spacing: 0) {
            if let flow {
                ProjectFlowView(flow: flow, text: flow == .openFolder ? Self.folderText(model.openFolderStart) : "") { next in
                    self.flow = next
                    if next == nil {
                        text = ""
                        Task { isFieldFocused = true }
                    }
                }
                .id(flow)
            } else if let archived {
                ArchivedTranscript(session: archived, project: model.project(archived.projectID)) {
                    self.archived = nil
                    isFieldFocused = true
                }
            } else {
                field(rows)
                list(sections)
            }
        }
        .frame(width: 640)
        .panelSurface()
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, 96)
        .onChange(of: rows.map(\.id)) { _, ids in
            if !ids.contains(where: { $0 == selection }) { selection = ids.first }
        }
        .onChange(of: text) {
            PointerHover.settle()
            selection = content.sections.first?.rows.first?.id
        }
        .onAppear {
            PointerHover.settle()
            selection = rows.first?.id
        }
        .task {
            isFieldFocused = true
            if let session = model.actionContext(via: .palette).session { await model.loadModelChoices(for: session.provider) }
            stored = await search.allSessions()
        }
        .task(id: query) {
            guard query.searchesTranscripts else {
                hits = []
                return
            }
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            hits = await search.results(for: query.text, in: sessions)
        }
    }

    private var query: PaletteQuery { PaletteQuery(text) }

    private var search: SessionSearch { SessionSearch(store: model.services.store) }

    /// Stored sessions with live ones laid over them, since the store saves after a debounce.
    private var sessions: [UUID: Session] {
        stored.merging(model.sessionsByID) { _, live in live }
    }

    private var content: PaletteContent {
        PaletteContent(model: model, query: query, sessions: sessions, transcriptHits: hits)
    }

    private func field(_ rows: [PaletteRow]) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "command").font(.system(size: 14)).foregroundStyle(Palette.textTertiary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.ui(15))
                .focused($isFieldFocused)
                .onSubmit { run(selection, in: rows, staying: false) }
                .onKeyPress(.downArrow) { move(1, in: rows) }
                .onKeyPress(.upArrow) { move(-1, in: rows) }
                .onKeyPress(.tab) { move(1, in: rows) }
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    run(selection, in: rows, staying: true)
                    return .handled
                }
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
    }

    private var placeholder: String {
        switch query.scope {
        case .everything: "Search, or type > @ /"
        case .commands: "Run a command"
        case .sessions: "Jump to a session or project"
        case .slashCommands: "Slash command for the focused session"
        }
    }

    @ViewBuilder private func list(_ sections: [PaletteSection]) -> some View {
        if sections.isEmpty {
            Text(emptyText)
                .font(.ui(13))
                .foregroundStyle(Palette.textTertiary)
                .padding(16)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(sections) { section in
                            Text(section.title)
                                .font(.ui(12, weight: .semibold))
                                .foregroundStyle(Palette.textTertiary)
                                .lineLimit(1)
                                .padding(.horizontal, 16)
                                .padding(.top, 8)
                                .padding(.bottom, 4)
                            ForEach(section.rows) { row in
                                PaletteRowView(row: row, project: project(of: row), isSelected: selection == row.id)
                                    .id(row.id)
                                    .onTapGesture { run(row.id, in: sections.flatMap(\.rows), staying: false) }
                                    .onContinuousHover { phase in
                                        if case .active = phase, PointerHover.moved() { selection = row.id }
                                    }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 440)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: selection) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
    }

    private var emptyText: String {
        if query.scope == .slashCommands, model.actionContext(via: .palette).session == nil { return "Focus a session to see its slash commands." }
        return query.text.isEmpty ? "Nothing here yet." : "Nothing matches \u{201C}\(query.text)\u{201D}."
    }

    private func project(of row: PaletteRow) -> Project? {
        switch row.kind {
        case .session(let session): model.project(session.projectID)
        case .project(let project): project
        default: nil
        }
    }

    private func move(_ offset: Int, in rows: [PaletteRow]) -> KeyPress.Result {
        guard !rows.isEmpty else { return .ignored }
        PointerHover.settle()
        let index = rows.firstIndex { $0.id == selection }.map { $0 + offset } ?? 0
        selection = rows[min(max(index, 0), rows.count - 1)].id
        return .handled
    }

    /// A folder as Local folder's field starts: abbreviated, ending in /.
    static func folderText(_ folder: URL) -> String {
        let path = DisplayPath.abbreviated(folder)
        return path.hasSuffix("/") ? path : path + "/"
    }

    private func run(_ id: String?, in rows: [PaletteRow], staying: Bool) {
        guard let row = rows.first(where: { $0.id == id }) else { return }
        // Add project and New project go on in the palette rather than closing it.
        if case .action(let action, _) = row.kind, !row.isUnavailable, let next = ProjectFlow(action) {
            model.recordPaletteUse(row.key)
            flow = next
            return
        }
        switch model.runPaletteRow(row, staying: staying) {
        case .done: break
        case .narrow(let text): self.text = text
        case .showArchived(let session): archived = session
        }
    }
}

/// What the palette does after running a row.
enum PaletteOutcome {
    case done
    case narrow(String)
    case showArchived(Session)
}

extension AppModel {
    /// Runs a palette row. Closing comes first, so an action can open its own sheet; with
    /// `staying` (⌘↵) the palette stays open, and a session row only takes focus, so the
    /// palette's session actions then act on it.
    func runPaletteRow(_ row: PaletteRow, staying: Bool) -> PaletteOutcome {
        switch row.kind {
        case .narrow(let text):
            return .narrow(text)
        case .action(let id, let argument):
            guard !row.isUnavailable else { return .done }
            recordPaletteUse(row.key)
            let palette = sheet
            if !staying { sheet = nil }
            if !perform(id, argument: argument, via: .palette), !staying { sheet = palette }
        case .session(let session):
            guard let live = sessionsByID[session.id], live.lifecycle != .archived else {
                return .showArchived(session)
            }
            recordPaletteUse(row.key)
            if let projectFilter, projectFilter != live.projectID { self.projectFilter = nil }
            if !showFilter.matches(live) { showFilter = .all }
            if staying {
                clearFront(keeping: .sheet)
                openedSessionID = nil
                focusedItem = .session(live.id)
            } else {
                clearFront()
                openSession(live.id)
            }
        case .project(let project):
            recordPaletteUse(row.key)
            if projectFilter != nil, projectFilter != project.id { projectFilter = nil }
            let first = geometry.orderedItems.first { item in
                switch item {
                case .session(let id): sessionsByID[id]?.projectID == project.id
                case .terminal(let id): terminalsByID[id]?.projectID == project.id
                }
            }
            if !staying { sheet = nil }
            if let first { focusedItem = first } else if !staying { perform(.sessionNew, argument: project.id.uuidString, via: .palette) }
        case .slashCommand(let item, let sessionID):
            recordPaletteUse(row.key)
            sheet = nil
            if openedSessionID != sessionID { focusedItem = .session(sessionID) }
            _ = startTyping(item.insertion)
        }
        return .done
    }
}

private struct PaletteRowView: View {
    let row: PaletteRow
    let project: Project?
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                icon.frame(width: 16).opacity(row.isUnavailable ? 0.5 : 1)
                Text(row.title)
                    .font(.ui(13))
                    .foregroundStyle(row.isUnavailable ? Palette.textTertiary : Palette.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if isArchived {
                    Text("archived").font(.ui(12)).foregroundStyle(Palette.textTertiary)
                }
                if let detail = row.detail {
                    Text(detail).font(.ui(12)).foregroundStyle(Palette.textTertiary).lineLimit(1).truncationMode(.middle)
                }
                // Plain text, as a menu shows its key equivalents.
                if let shortcut = row.shortcut {
                    Text(KeyChips.caps(for: shortcut.strokes).map { $0 == "space" ? "Space" : $0.count == 1 ? $0.uppercased() : $0 }.joined(separator: " ")).font(.ui(12)).foregroundStyle(Palette.textTertiary)
                }
            }
            if let snippet = row.snippet {
                Text(snippet)
                    .font(.ui(12))
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(2)
                    .padding(.leading, 24)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 32)
        .padding(.vertical, row.snippet == nil ? 0 : 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Palette.rowCursor : .clear, in: .rect(cornerRadius: 8))
        .padding(.horizontal, 4)
        .contentShape(.rect)
    }


    private var isArchived: Bool {
        if case .session(let session) = row.kind { session.lifecycle == .archived } else { false }
    }

    @ViewBuilder private var icon: some View {
        switch row.kind {
        case .session(let session):
            HStack(spacing: 0) {
                RunGlyph(runState: session.runState)
            }
        case .project(let project):
            ProjectMark(project: project)
        case .slashCommand:
            Text("/").font(.ui(13)).foregroundStyle(Palette.textTertiary)
        case .action, .narrow:
            Image(systemName: row.systemImage ?? "chevron.right")
                .font(.system(size: 12))
                .foregroundStyle(Palette.icon)
        }
    }
}
