import ConstellationCore
import Foundation

/// One row of the ⌘K palette and what running it does.
struct PaletteRow: Identifiable {
    enum Kind {
        case action(ActionID, argument: String?)
        /// An action whose rows need an argument: running it narrows the palette to them.
        case narrow(to: String)
        case session(Session)
        case project(Project)
        case slashCommand(ComposerMenuItem, sessionID: UUID)
    }

    let kind: Kind
    let title: String
    var detail: String?
    var keywords: [String] = []
    var systemImage: String?
    var shortcut: KeyBinding?
    var snippet: AttributedString?
    /// A command that matches but can't run now, listed dimmed with why.
    var isUnavailable = false
    /// How recents remember it.
    let key: String

    var id: String { key }
}

struct PaletteSection: Identifiable {
    let id: String
    let title: String
    let rows: [PaletteRow]
}

/// Builds the palette's sections for a query: the focused session's actions, sessions and
/// projects, commands, then transcript matches.
@MainActor
struct PaletteContent {
    let model: AppModel
    let query: PaletteQuery
    /// Every stored session, archived ones included, with live ones laid over them.
    let sessions: [UUID: Session]
    let transcriptHits: [SearchResult]

    private var context: ActionContext { model.actionContext(via: .palette) }
    private var recents: [String] { model.paletteRecents }

    var sections: [PaletteSection] {
        var sections: [PaletteSection] = []
        func add(_ id: String, _ title: String, _ rows: [PaletteRow]) {
            if !rows.isEmpty { sections.append(PaletteSection(id: id, title: title, rows: rows)) }
        }
        switch query.scope {
        case .everything:
            if let session = context.session { add("session", "On \(session.title)", actionRows(.session)) }
            add("sessions", query.text.isEmpty ? "Recent sessions" : "Sessions and projects", sessionRows(limit: query.text.isEmpty ? 5 : 8))
            add("commands", "Commands", actionRows(.command))
            add("transcripts", "In transcripts", transcriptRows(excluding: Set(sections.flatMap(\.rows).map(\.key))))
        case .commands:
            if let session = context.session { add("session", "On \(session.title)", actionRows(.session)) }
            add("commands", "Commands", actionRows(.command))
        case .sessions:
            add("sessions", "Sessions and projects", sessionRows(limit: 30))
            add("transcripts", "In transcripts", transcriptRows(excluding: Set(sections.flatMap(\.rows).map(\.key))))
        case .slashCommands:
            if let session = context.session { add("slash", "Slash commands in \(session.title)", slashRows(for: session)) }
        }
        return sections
    }

    // MARK: Actions

    private func actionRows(_ section: PaletteAction.Section) -> [PaletteRow] {
        let context = context
        var rows: [PaletteRow] = []
        var unavailable: [PaletteRow] = []
        for action in ActionRegistry.all where action.section == section {
            if section == .session, context.session == nil { break }
            let variants = (action.variants?(context) ?? []).filter { action.canRun(context, argument: $0.argument) }
            let showsVariants = !query.text.isEmpty || action.expandsInPalette
            if action.canRun(context, argument: nil) {
                rows.append(row(for: action, argument: nil, title: action.title(in: context), keywords: action.keywords))
            } else if section == .command, query.text.count >= 3, variants.isEmpty, action.variants == nil {
                var row = row(for: action, argument: nil, title: action.title(in: context), keywords: [])
                row.isUnavailable = true
                row.detail = action.unavailableReason ?? "Not available now"
                row.shortcut = nil
                unavailable.append(row)
            } else if query.text.isEmpty, !variants.isEmpty, !action.expandsInPalette {
                rows.append(PaletteRow(
                    kind: .narrow(to: ">\(action.title) "),
                    title: action.title(in: context) + "…",
                    keywords: action.keywords,
                    systemImage: action.systemImage,
                    key: action.id.rawValue
                ))
            }
            let recent = Set(recents)
            for variant in variants where showsVariants || recent.contains(AppModel.paletteKey(action.id, argument: variant.argument)) {
                rows.append(row(for: action, argument: variant.argument, title: variant.title, keywords: variant.keywords + action.keywords))
            }
        }
        // Matched by title only, and after everything that can run, so ↵ never lands on one.
        return PaletteRanking.rank(query.text, rows, recents: recents, key: \.key, title: \.title, keywords: \.keywords)
            + PaletteRanking.rank(query.text, unavailable, recents: [], key: \.key, title: \.title, keywords: \.keywords)
    }

    private func row(for action: PaletteAction, argument: String?, title: String, keywords: [String]) -> PaletteRow {
        PaletteRow(
            kind: .action(action.id, argument: argument),
            title: title,
            keywords: keywords,
            systemImage: action.systemImage,
            shortcut: model.binding(for: action.id, argument: argument),
            key: AppModel.paletteKey(action.id, argument: argument)
        )
    }

    // MARK: Sessions and projects

    private func sessionRows(limit: Int) -> [PaletteRow] {
        let byActivity = sessions.values.sorted { $0.lastActivityAt > $1.lastActivityAt }
        var rows = byActivity.map(sessionRow)
        if !query.text.isEmpty || query.scope == .sessions {
            rows += model.projects.map { project in
                PaletteRow(
                    kind: .project(project),
                    title: project.name,
                    detail: project.rootPath.path(percentEncoded: false).abbreviatingHome,
                    keywords: ["project"],
                    systemImage: "folder.fill",
                    key: "project:\(project.id.uuidString)"
                )
            }
        }
        return Array(PaletteRanking.rank(query.text, rows, recents: recents, key: \.key, title: \.title, keywords: \.keywords).prefix(limit))
    }

    private func sessionRow(_ session: Session) -> PaletteRow {
        let project = model.project(session.projectID)
        let age = session.lastActivityAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
        return PaletteRow(
            kind: .session(session),
            title: session.title,
            detail: [project?.name, session.branch.isEmpty ? nil : session.branch, age].compactMap(\.self).joined(separator: " · "),
            keywords: [session.branch, project?.name].compactMap(\.self),
            key: "session:\(session.id.uuidString)"
        )
    }

    private func transcriptRows(excluding shown: Set<String>) -> [PaletteRow] {
        guard query.searchesTranscripts else { return [] }
        return transcriptHits.prefix(10).compactMap { hit in
            var row = sessionRow(hit.session)
            guard !shown.contains(row.key) else { return nil }
            row.snippet = hit.snippet
            return row
        }
    }

    // MARK: Slash commands

    private func slashRows(for session: Session) -> [PaletteRow] {
        let items = model.slashCommandItems(for: session)
        return FuzzyMatch.rank(query.text, items, limit: 30, text: \.title).map { item in
            PaletteRow(
                kind: .slashCommand(item, sessionID: session.id),
                title: item.title,
                detail: item.detail.isEmpty ? item.badge : item.detail,
                key: "slash:\(item.id)"
            )
        }
    }
}

private extension String {
    var abbreviatingHome: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        return hasPrefix(home) ? "~/" + dropFirst(home.count).drop { $0 == "/" } : self
    }
}
