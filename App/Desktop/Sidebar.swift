import ConstellationCore
import SwiftUI

/// Hosts and projects, the Show filter, and the Merged and idle row.
struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Hugs its content, and scrolls only when the screen is too short for it.
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }.scrollIndicators(.never)
        }
        .frame(width: 236)
        .panelSurface()
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                Text("Constellation").font(.ui(13, weight: .semibold)).foregroundStyle(Palette.text)
                Spacer(minLength: 8)
                SidebarButton(isInPanel: true)
            }
            .padding(.leading, 10)
            .padding(.bottom, 6)

            Button { model.toggleProjectFilter(nil) } label: {
                RowIcon(systemName: "square.stack")
                Text("All projects").frame(maxWidth: .infinity, alignment: .leading)
                Count(value: model.count(.all))
            }
            .buttonStyle(SidebarRowStyle(isSelected: model.projectFilter == nil))

            SectionHeader("Projects")
            ForEach(model.projects) { project in
                ProjectRow(project: project)
            }
            Button { model.perform(.projectAdd) } label: {
                RowIcon(systemName: "plus")
                Text("Add project…").foregroundStyle(Palette.textSecondary)
            }
            .buttonStyle(SidebarRowStyle())

            // Every count is of live sessions, drafts and archived ones aside, so Everything matches
            // All projects and the project rows add up to it. A filter with nothing in it hides,
            // unless it's the one showing.
            SectionHeader("Show")
            ForEach(ShowFilter.allCases) { filter in
                let count = model.count(filter)
                if filter == .all || count > 0 || model.showFilter == filter {
                    Button { model.perform(.showFilter, argument: filter.rawValue) } label: {
                        RowIcon(systemName: filter.symbol, color: color(of: filter))
                        Text(filter.title).frame(maxWidth: .infinity, alignment: .leading)
                        Count(value: count)
                    }
                    .buttonStyle(SidebarRowStyle(isSelected: model.showFilter == filter))
                }
            }

            SectionHeader("Put away")
            Button { model.perform(.cleanup) } label: {
                RowIcon(systemName: "trash")
                Text("Merged and idle").foregroundStyle(Palette.textSecondary).frame(maxWidth: .infinity, alignment: .leading)
                Count(value: model.recededCount)
            }
            .buttonStyle(SidebarRowStyle())

            Button { model.perform(.palette, argument: "@") } label: {
                RowIcon(systemName: "archivebox")
                Text("Archived").foregroundStyle(Palette.textSecondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(SidebarRowStyle())
            .help("Search every session, archived ones included" + (model.binding(for: .palette).map { " (\($0.label))" } ?? ""))

        }
        .padding(10)
    }

    private func color(of filter: ShowFilter) -> Color {
        switch filter {
        case .all: Palette.icon
        case .needsYou: Palette.ask
        case .failed: Palette.error
        case .working: Palette.working
        case .doneNotSeen: Palette.done
        }
    }
}

private struct ProjectRow: View {
    @Environment(AppModel.self) private var model
    let project: Project

    var body: some View {
        let sessions = model.sessionsByID.values.filter { $0.projectID == project.id && !$0.isDraft && $0.lifecycle != .archived }
        let blocked = sessions.count { $0.runState == .blocked }
        let failed = sessions.count { if case .failed = $0.runState { true } else { false } }
        Button { model.perform(.projectFilter, argument: project.id.uuidString) } label: {
            ProjectMark(project: project, size: 14).frame(width: 16)
            Text(project.name).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
            if blocked > 0 { Text("\(Glyph.blocked) \(blocked)").font(.ui(12)).monospacedDigit().foregroundStyle(Palette.ask) }
            if failed > 0 { Text("\(Glyph.failed) \(failed)").font(.ui(12)).monospacedDigit().foregroundStyle(Palette.error) }
            if blocked == 0, failed == 0 { Count(value: sessions.count) }
        }
        .buttonStyle(SidebarRowStyle(isSelected: model.projectFilter == project.id))
        .contextMenu {
            ActionButton(.sessionNew, argument: project.id.uuidString, title: "New Session…")
            ActionButton(.terminalNew, argument: project.id.uuidString, title: "Open Terminal")
            ActionButton(.browserNew, argument: project.id.uuidString, title: "Open Browser")
            ActionButton(.noteNew, argument: project.id.uuidString, title: "New Note")
            let tasks = model.suggestedTasks(for: project)
            if !tasks.isEmpty {
                Menu("Run Task") {
                    ForEach(tasks, id: \.self) { task in
                        ActionButton(.taskRun, argument: "\(project.id.uuidString)|\(task.name)", title: task.name)
                    }
                }
            }
            ActionButton(.projectShowInFinder, argument: project.id.uuidString, title: "Show in Finder")
            Divider()
            ActionButton(.projectRemove, argument: project.id.uuidString, title: "Remove Project…")
        }
    }
}

private struct SectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.ui(12, weight: .medium))
            .foregroundStyle(Palette.textTertiary)
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .frame(height: 28, alignment: .bottom)
    }
}

private struct Count: View {
    let value: Int

    var body: some View {
        Text("\(value)").font(.ui(12)).monospacedDigit().foregroundStyle(Palette.textTertiary)
    }
}

/// A row's icon: an SF Symbol in a fixed-width column so every label starts in the same place.
private struct RowIcon: View {
    let systemName: String
    var color: Color = Palette.icon

    var body: some View {
        Image(systemName: systemName).font(.system(size: 12, weight: .medium)).foregroundStyle(color).frame(width: 16)
    }
}

/// Shows or hides the sidebar: a quiet icon at the top left of the desktop while it's hidden, and
/// in the sidebar's own header while it's shown.
struct SidebarButton: View {
    @Environment(AppModel.self) private var model
    var isInPanel = false
    @State private var isHovered = false

    var body: some View {
        Button { model.perform(.sidebarToggle) } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isHovered ? Palette.text : Palette.textSecondary)
                .frame(width: isInPanel ? 26 : 32, height: isInPanel ? 26 : 32)
                .background {
                    if isInPanel {
                        RoundedRectangle(cornerRadius: 8).fill(isHovered ? Palette.rowHover : .clear)
                    } else {
                        RoundedRectangle(cornerRadius: 10).fill(.ultraThinMaterial)
                            .overlay(RoundedRectangle(cornerRadius: 10).fill(Palette.popover.opacity(isHovered ? 0.7 : 0.55)))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.edge))
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.constellation, value: isHovered)
        .help(model.isSidebarShown ? "Hide the sidebar" : "Show the sidebar")
    }
}
