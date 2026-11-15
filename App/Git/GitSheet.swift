import ConstellationCore
import ConstellationGit
import SwiftUI

/// Commit, Push, Create PR or Merge for one session, over the desktop or the session view. The text is
/// pre-filled and editable; failures show inline and leave the sheet open. ⌘↵ runs the action.
struct GitSheet: View {
    @Environment(AppModel.self) private var model
    let session: Session
    @State var action: GitAction

    /// Where the sheet is: reading the worktree, showing the form, running the action, a failure,
    /// or finished.
    private enum Phase: Equatable {
        case loading
        case ready
        case running
        /// `afterLoad`: the worktree couldn't be read, so there is no form to run. Otherwise the run
        /// failed and the form stays as it was, to try again.
        case failed(String, afterLoad: Bool)
        case done(String)
    }

    @State private var phase = Phase.loading

    @State private var changes: [WorkingChange] = []
    @State private var unticked: Set<String> = []
    @State private var message = ""
    @State private var pushState: PushState?
    @State private var draft = PullRequestDraft(title: "", body: "", base: "", head: "")
    @State private var mergePreview: MergePreview?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Group {
                switch phase {
                case .loading:
                    Text("\(Image(systemName: "hourglass")) Reading the worktree…")
                        .font(.ui(13))
                        .foregroundStyle(Palette.textSecondary)
                case .done(let done):
                    Text("\(Glyph.done) \(done)")
                        .font(.ui(13))
                        .foregroundStyle(Palette.text)
                        .textSelection(.enabled)
                case .failed(let error, afterLoad: true):
                    failure(error)
                case .ready, .running, .failed:
                    content
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            footer
        }
        .frame(width: 640)
        .panelSurface()
        .task(id: action) { await load() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(heading).font(.ui(16, weight: .medium))
            HStack(spacing: 8) {
                Text(session.title).lineLimit(1)
                Text(pushState?.branch ?? session.branch)
                    .font(.ui(12))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.ui(13))
            .foregroundStyle(Palette.textTertiary)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }

    private var heading: String {
        switch action {
        case .commit: "Commit"
        case .push: "Push"
        case .pullRequest: "Create pull request"
        case .merge: "Merge into \(mergePreview?.base ?? session.baseBranch)"
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch action {
        case .commit: commitForm
        case .push: pushSummary
        case .pullRequest: pullRequestForm
        case .merge: mergeSummary
        }
    }

    private var commitForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            if changes.isEmpty {
                Text("Nothing to commit: the worktree is clean.").font(.ui(13)).foregroundStyle(Palette.textSecondary)
            } else {
                Toggle(isOn: Binding(
                    get: { unticked.isEmpty },
                    set: { unticked = $0 ? [] : Set(changes.map(\.id)) }
                )) {
                    Text(changes.count == 1 ? "1 changed file" : "\(changes.count) changed files")
                        .font(.ui(13, weight: .medium))
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(changes) { change in
                            ChangeRow(change: change, isOn: Binding(
                                get: { !unticked.contains(change.id) },
                                set: { if $0 { unticked.remove(change.id) } else { unticked.insert(change.id) } }
                            ))
                        }
                    }
                }
                .frame(height: min(240, Double(changes.count) * 26 + 4))
                .padding(.leading, 20)
                label("Message")
                editor($message, mono: false, height: 120)
            }
        }
        .toggleStyle(.checkbox)
        .tint(Palette.ask)
    }

    private var pushSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let state = pushState {
                Text(pushDescription(state)).font(.ui(13)).foregroundStyle(Palette.text)
                uncommittedNote(state)
            }
        }
    }

    private var pullRequestForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            label("Title")
            TextField("Title", text: $draft.title)
                .textFieldStyle(.plain)
                .font(.ui(13))
                .padding(8)
                .background(Palette.surfaceSunken, in: .rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.text.opacity(0.14)))
            label("Description")
            editor($draft.body, mono: true, height: 200)
            HStack(spacing: 16) {
                HStack(spacing: 8) {
                    label("Into")
                    TextField("Base branch", text: $draft.base)
                        .textFieldStyle(.plain)
                        .font(.ui(12))
                        .padding(.horizontal, 8)
                        .frame(width: 160, height: 26)
                        .background(Palette.surfaceSunken, in: .rect(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.text.opacity(0.14)))
                }
                Toggle("Draft", isOn: $draft.isDraft)
                    .toggleStyle(.checkbox)
                    .tint(Palette.ask)
                    .font(.ui(13))
            }
            if let state = pushState {
                if state.needsPush, let branch = state.branch {
                    Text("Pushes \(branch) to origin first.").font(.ui(12)).foregroundStyle(Palette.textTertiary)
                }
                uncommittedNote(state)
            }
        }
    }

    private var mergeSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let preview = mergePreview {
                Text(mergeDescription(preview)).font(.ui(13)).foregroundStyle(Palette.text)
                if !preview.conflicts.isEmpty {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(preview.conflicts, id: \.self) { file in
                                Text(file).font(.ui(12)).foregroundStyle(Palette.text).lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                    .frame(height: min(160, Double(preview.conflicts.count) * 20 + 4))
                    .padding(.leading, 20)
                }
                if preview.uncommittedFiles > 0 {
                    HStack(spacing: 8) {
                        Text(preview.uncommittedFiles == 1 ? "! 1 uncommitted file. Commit it before merging." : "! \(preview.uncommittedFiles) uncommitted files. Commit them before merging.")
                            .font(.ui(12))
                            .foregroundStyle(Palette.ask)
                        Button("Commit…") { action = .commit }
                            .buttonStyle(ConstellationButtonStyle(weight: .quiet, height: 22))
                    }
                }
            }
        }
    }

    private func mergeDescription(_ preview: MergePreview) -> String {
        guard let branch = preview.branch else { return "HEAD is detached, so there is no branch to merge." }
        let base = preview.base
        if !preview.conflicts.isEmpty {
            let files = preview.conflicts.count == 1 ? "this file" : "these files"
            return "\(branch) and \(base) both changed \(files), so merging would conflict. Nothing has been merged."
        }
        if preview.commits == 0 { return "\(branch) has no commits that \(base) lacks." }
        let commits = preview.commits == 1 ? "1 commit" : "\(preview.commits) commits"
        return "Merge \(commits) from \(branch) into \(base) on this Mac. Nothing is pushed."
    }

    @ViewBuilder private func uncommittedNote(_ state: PushState) -> some View {
        if state.uncommittedFiles > 0 {
            HStack(spacing: 8) {
                Text(state.uncommittedFiles == 1 ? "! 1 uncommitted file won't be included." : "! \(state.uncommittedFiles) uncommitted files won't be included.")
                    .font(.ui(12))
                    .foregroundStyle(Palette.ask)
                Button("Commit…") { action = .commit }
                    .buttonStyle(ConstellationButtonStyle(weight: .quiet, height: 22))
            }
        }
    }

    private func pushDescription(_ state: PushState) -> String {
        guard let branch = state.branch else { return "HEAD is detached, so there is no branch to push." }
        guard state.hasOrigin else { return "This repository has no remote called origin." }
        let commits = state.unpushedCommits == 1 ? "1 commit" : "\(state.unpushedCommits) commits"
        if !state.hasUpstream { return "Push \(branch) to origin with \(commits) and track it there." }
        if state.unpushedCommits == 0 { return "\(branch) is up to date with its upstream." }
        return "Push \(commits) on \(branch) to origin."
    }

    private func failure(_ error: String) -> some View {
        Text("\(Glyph.failed) \(error)")
            .font(.ui(12))
            .foregroundStyle(Palette.error)
            .lineLimit(6)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.ui(12)).foregroundStyle(Palette.textTertiary)
    }

    private func editor(_ text: Binding<String>, mono: Bool, height: Double) -> some View {
        TextEditor(text: text)
            .font(mono ? .ui(12) : .ui(13))
            .scrollContentBackground(.hidden)
            .padding(8)
            .frame(height: height)
            .background(Palette.surfaceSunken, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.text.opacity(0.14)))
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if case .failed(let error, afterLoad: false) = phase {
                failure(error)
            } else {
                Spacer(minLength: 0)
            }
            if case .done = phase {
                if action == .commit {
                    Button("Push") { switchTo(.push) }.buttonStyle(ConstellationButtonStyle(weight: .secondary, height: 32))
                    Button("Create PR…") { switchTo(.pullRequest) }.buttonStyle(ConstellationButtonStyle(weight: .secondary, height: 32))
                    if session.usesWorktree {
                        Button(GitAction.merge.title(for: session)) { switchTo(.merge) }
                            .buttonStyle(ConstellationButtonStyle(weight: .secondary, height: 32))
                    }
                }
                Button("Done") { model.dismissSheet() }
                    .buttonStyle(ConstellationButtonStyle(weight: .primary, height: 32))
                    .keyboardShortcut(.return, modifiers: .command)
            } else {
                Button("Cancel") { model.dismissSheet() }
                    .buttonStyle(ConstellationButtonStyle(weight: .secondary, height: 32))
                Button(phase == .running ? runningTitle : runTitle, action: run)
                    .buttonStyle(ConstellationButtonStyle(weight: .primary, height: 32))
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("\(runTitle) (⌘↵)")
                .disabled(!canRun)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(Color(hex: 0x181715))
        .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }

    private var ticked: [WorkingChange] {
        changes.filter { !unticked.contains($0.id) }
    }

    private var runTitle: String {
        switch action {
        case .commit: ticked.count == changes.count ? "Commit" : "Commit \(ticked.count)"
        case .push: "Push"
        case .pullRequest: draft.isDraft ? "Create draft PR" : "Create PR"
        case .merge:
            if let preview = mergePreview, !preview.conflicts.isEmpty { "Ask the agent to rebase onto \(preview.base)" } else { "Merge" }
        }
    }

    private var runningTitle: String {
        switch action {
        case .commit: "Committing…"
        case .push: "Pushing…"
        case .pullRequest: "Creating…"
        case .merge: "Merging…"
        }
    }

    private var canRun: Bool {
        switch phase {
        case .ready, .failed(_, afterLoad: false): break
        case .loading, .running, .failed, .done: return false
        }
        switch action {
        case .commit:
            return !ticked.isEmpty && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .push:
            guard let state = pushState else { return false }
            return state.branch != nil && state.hasOrigin && state.needsPush
        case .pullRequest:
            return !draft.title.trimmingCharacters(in: .whitespaces).isEmpty && !draft.base.isEmpty && pushState?.branch != nil
        case .merge:
            guard let preview = mergePreview else { return false }
            return preview.canMerge || !preview.conflicts.isEmpty
        }
    }

    // MARK: Actions

    private func switchTo(_ next: GitAction) {
        action = next
    }

    /// Reads what the action needs afresh, nothing from the last read kept, so nothing runs on what
    /// the worktree used to be. A load cancelled by another (the action changed) leaves the new one be.
    private func load() async {
        phase = .loading
        changes = []
        pushState = nil
        mergePreview = nil
        do {
            switch action {
            case .commit:
                let preparation = try await model.prepareCommit(for: session.id)
                guard !Task.isCancelled else { return }
                changes = preparation.changes
                unticked = []
                if message.isEmpty { message = preparation.message }
            case .push:
                let state = try await model.pushState(for: session.id)
                guard !Task.isCancelled else { return }
                pushState = state
            case .pullRequest:
                let preparation = try await model.preparePullRequest(for: session.id)
                guard !Task.isCancelled else { return }
                pushState = preparation.push
                if draft.title.isEmpty { draft = preparation.draft }
            case .merge:
                let preview = try await model.mergePreview(for: session.id)
                guard !Task.isCancelled else { return }
                mergePreview = preview
            }
            phase = .ready
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(error.gitActionMessage, afterLoad: true)
        }
    }

    private func run() {
        guard canRun else { return }
        phase = .running
        Task {
            do {
                switch action {
                case .commit:
                    let hash = try await model.commit(ticked, message: message, for: session.id)
                    let count = ticked.count == 1 ? "1 file" : "\(ticked.count) files"
                    phase = .done("Committed \(count) as \(hash).")
                    message = ""
                case .push:
                    try await model.push(session.id)
                    phase = .done("Pushed \(pushState?.branch ?? session.branch) to origin.")
                case .pullRequest:
                    let url = try await model.createPullRequest(draft, for: session.id)
                    phase = .done("Created \(draft.isDraft ? "draft " : "")PR \(url.absoluteString). It shows on the tile once GitHub reports it.")
                case .merge:
                    guard let preview = mergePreview else { return phase = .ready }
                    if preview.conflicts.isEmpty {
                        try await model.merge(preview, for: session.id)
                    } else {
                        model.askToRebase(session.id, onto: preview.base, conflicts: preview.conflicts)
                    }
                    model.dismissSheet()
                }
            } catch {
                phase = .failed(error.gitActionMessage, afterLoad: false)
            }
        }
    }
}

private struct ChangeRow: View {
    let change: WorkingChange
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 8) {
                Text(badge)
                    .font(.ui(12, weight: .medium))
                    .foregroundStyle(change.kind == .deleted || change.kind == .conflicted ? Palette.error : Palette.textTertiary)
                    .frame(width: 12)
                Text(change.originalPath.map { "\($0) → \(change.path)" } ?? change.path)
                    .font(.ui(12))
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(height: 24)
    }

    private var badge: String {
        switch change.kind {
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .untracked: "?"
        case .conflicted: "U"
        }
    }
}
