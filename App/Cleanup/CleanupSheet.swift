import ConstellationCore
import SwiftUI

/// Clean up merged work: candidates grouped by project, options, the space freed and Archive N (⌘↵).
/// Arrows move between rows, space toggles one, esc cancels.
struct CleanupSheet: View {
    @Environment(AppModel.self) private var model
    @State private var inspections: [UUID: WorktreeInspection] = [:]
    @State private var isInspecting = true
    @State private var isArchiving = false
    @State private var threshold = CleanupThreshold.default
    @State private var deletesBranches = true
    @State private var projectFilter: UUID?
    /// Ticks you changed; everything else follows the candidate's default.
    @State private var overrides: [UUID: Bool] = [:]
    @State private var highlighted: UUID?
    @FocusState private var isFocused: Bool

    var body: some View {
        let rows = self.rows
        let shown = rows.filter { projectFilter == nil || $0.session.projectID == projectFilter }
        let ticked = shown.filter(isTicked)
        VStack(alignment: .leading, spacing: 0) {
            header(rows)
            list(shown)
            options
            footer(ticked)
        }
        .frame(width: 760)
        .panelSurface()
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(.space) { toggleHighlighted(in: shown) }
        .onKeyPress(.downArrow) { moveHighlight(by: 1, in: shown) }
        .onKeyPress(.upArrow) { moveHighlight(by: -1, in: shown) }
        .task {
            threshold = model.cleanupThreshold
            deletesBranches = model.cleanupDeletesBranches
            isFocused = true
            inspections = await model.inspectWorktrees(of: model.recededDoneSessions)
            isInspecting = false
        }
    }

    private var rows: [CleanupRow] {
        let candidates = CleanupCandidates.candidates(
            sessions: model.recededDoneSessions,
            facts: inspections.mapValues(\.facts),
            threshold: threshold
        )
        return candidates.compactMap { candidate in
            model.sessionsByID[candidate.sessionID].map {
                CleanupRow(candidate: candidate, session: $0, inspection: inspections[candidate.sessionID])
            }
        }
    }

    private func isTicked(_ row: CleanupRow) -> Bool {
        overrides[row.id] ?? row.candidate.isTicked
    }

    // MARK: Header

    private func header(_ rows: [CleanupRow]) -> some View {
        let projectIDs = Set(rows.map(\.session.projectID))
        let projects = model.projects.filter { projectIDs.contains($0.id) }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Clean up merged work").font(.ui(16, weight: .medium))
                Text(threshold.subtitle).font(.ui(13)).foregroundStyle(Palette.textTertiary)
            }
            if projects.count > 1 {
                HStack(spacing: 4) {
                    FilterChip(title: "All", swatch: nil, isActive: projectFilter == nil) { projectFilter = nil }
                    ForEach(projects) { project in
                        FilterChip(title: project.name, swatch: project.swatch, isActive: projectFilter == project.id) {
                            projectFilter = project.id
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }

    // MARK: Rows

    @ViewBuilder private func list(_ rows: [CleanupRow]) -> some View {
        if isInspecting {
            message(Text("\(Image(systemName: "hourglass")) Checking worktrees…"))
        } else if rows.isEmpty {
            message(Text(threshold == .never
                ? "Choose when to suggest clean-up below."
                : "Nothing to clean up. Sessions show up here once they're merged or idle."))
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groups(rows), id: \.project.id) { group in
                            HStack(spacing: 8) {
                                ProjectMark(project: group.project)
                                Text(group.project.name).font(.ui(12))
                            }
                            .foregroundStyle(Palette.textTertiary)
                            .padding(.horizontal, 24)
                            .padding(.top, 16)
                            .padding(.bottom, 8)
                            ForEach(group.rows) { row in
                                CleanupRowView(row: row, isTicked: isTicked(row), isHighlighted: highlighted == row.id) {
                                    overrides[row.id] = !isTicked(row)
                                    highlighted = row.id
                                }
                                .id(row.id)
                            }
                        }
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 12)
                }
                .frame(height: min(440, Double(rows.count) * 44 + Double(groups(rows).count) * 40 + 16))
                .onChange(of: highlighted) { _, id in
                    if let id { withAnimation(.hover) { proxy.scrollTo(id) } }
                }
            }
        }
    }

    private func groups(_ rows: [CleanupRow]) -> [(project: Project, rows: [CleanupRow])] {
        model.projects.compactMap { project in
            let rows = rows.filter { $0.session.projectID == project.id }
            return rows.isEmpty ? nil : (project, rows)
        }
    }

    private func message(_ text: Text) -> some View {
        text.font(.ui(13))
            .foregroundStyle(Palette.textSecondary)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Options

    private var options: some View {
        HStack(spacing: 24) {
            Toggle("Delete merged local branches", isOn: Binding(
                get: { deletesBranches },
                set: { deletesBranches = $0; model.cleanupDeletesBranches = $0 }
            ))
            Toggle("Keep transcripts searchable", isOn: .constant(true))
                .disabled(true)
                .help("Archived transcripts always stay searchable with ⌘K.")
            HStack(spacing: 8) {
                Text("Suggest after")
                Picker("Suggest after", selection: Binding(
                    get: { threshold },
                    set: { threshold = $0; model.cleanupThreshold = $0 }
                )) {
                    ForEach(CleanupThreshold.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
        .toggleStyle(.checkbox)
        .tint(Palette.text)
        .font(.ui(13))
        .foregroundStyle(Palette.textSecondary)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }

    // MARK: Footer

    private func footer(_ ticked: [CleanupRow]) -> some View {
        let freed = ticked.reduce(Int64(0)) { $0 + $1.candidate.bytesFreed }
        let worktrees = ticked.count { $0.candidate.bytesFreed > 0 }
        let branches = deletesBranches ? ticked.count(where: \.deletesBranch) : 0
        return HStack(spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(CleanupRow.bytes(freed))
                    .font(.ui(28, weight: .medium)).monospacedDigit()
                    .foregroundStyle(Palette.text)
                    .contentTransition(.numericText())
                    .animation(.hover, value: freed)
                Text(summary(worktrees: worktrees, branches: branches))
                    .font(.ui(13))
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer(minLength: 0)
            Button("Cancel") { model.dismissSheet() }
                .buttonStyle(ConstellationButtonStyle(weight: .quiet, height: 32))
            Button(isArchiving ? "Archiving…" : "Archive \(ticked.count)") { archive(ticked) }
                .buttonStyle(ConstellationButtonStyle(weight: .primary, height: 32))
                .keyboardShortcut(.return, modifiers: .command)
                .help("Archive (⌘↵)")
            .disabled(ticked.isEmpty || isArchiving || isInspecting)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(Color(hex: 0x181715))
        .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }

    private func summary(worktrees: Int, branches: Int) -> String {
        let trees = worktrees == 1 ? "1 worktree" : "\(worktrees) worktrees"
        guard branches > 0 else { return "from \(trees)" }
        return "from \(trees) and " + (branches == 1 ? "1 branch" : "\(branches) branches")
    }

    // MARK: Actions

    private func archive(_ rows: [CleanupRow]) {
        guard !rows.isEmpty, !isArchiving else { return }
        isArchiving = true
        let ids = rows.map(\.id)
        Task {
            let problems = await model.archive(ids, deletesBranches: deletesBranches)
            isArchiving = false
            if let first = problems.first {
                model.notice = problems.count == 1 ? first : "\(first) And \(problems.count - 1) more."
            }
            model.dismissSheet()
        }
    }

    private func toggleHighlighted(in rows: [CleanupRow]) -> KeyPress.Result {
        guard let row = rows.first(where: { $0.id == highlighted }) else {
            highlighted = rows.first?.id
            return .handled
        }
        overrides[row.id] = !isTicked(row)
        return .handled
    }

    private func moveHighlight(by offset: Int, in rows: [CleanupRow]) -> KeyPress.Result {
        guard !rows.isEmpty else { return .ignored }
        let ordered = groups(rows).flatMap(\.rows)
        let index = ordered.firstIndex { $0.id == highlighted }.map { $0 + offset } ?? (offset > 0 ? 0 : ordered.count - 1)
        highlighted = ordered[min(max(index, 0), ordered.count - 1)].id
        return .handled
    }
}

private struct CleanupRowView: View {
    let row: CleanupRow
    let isTicked: Bool
    let isHighlighted: Bool
    let toggle: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                Checkbox(isOn: isTicked)
                VStack(alignment: .leading, spacing: 0) {
                    Text(row.session.title).font(.ui(13)).foregroundStyle(Palette.text).lineLimit(1)
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(row.meta(now: context.date)).font(.ui(12)).foregroundStyle(Palette.textTertiary).lineLimit(1)
                    }
                }
                .frame(width: 220, alignment: .leading)
                HStack(spacing: 6) {
                    if row.detailIsWarning {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(Palette.ask)
                    }
                    Text(row.detail)
                        .font(.ui(12))
                        .foregroundStyle(row.detailIsWarning ? Palette.ask : Palette.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(row.fullPath)
                Text(row.size)
                    .font(.ui(12)).monospacedDigit()
                    .foregroundStyle(Palette.textSecondary)
                    .frame(width: 72, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .frame(height: 46)
            .background(isHovered || isHighlighted ? Palette.rowHover : .clear, in: .rect(cornerRadius: 10))
            .padding(.horizontal, 12)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.hover, value: isHovered)
    }
}

/// The canvas checkbox: ask-coloured when ticked.
private struct Checkbox: View {
    let isOn: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(isOn ? Palette.text : Palette.text.opacity(0.05))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(isOn ? .clear : Palette.text.opacity(0.2)))
            .overlay {
                if isOn {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.surface)
                }
            }
            .frame(width: 16, height: 16)
            .animation(.hover, value: isOn)
    }
}

private struct FilterChip: View {
    let title: String
    let swatch: ProjectSwatch?
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let swatch { SwatchMark(swatch: swatch) }
                Text(title).font(.ui(12))
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .foregroundStyle(isActive ? Palette.text : Palette.textSecondary)
            .background(isActive ? Palette.surfaceRaised : .clear, in: .rect(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isActive ? Palette.text.opacity(0.16) : .clear))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .animation(.hover, value: isActive)
    }
}
