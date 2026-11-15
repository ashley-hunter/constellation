import AppKit
import ConstellationCore
import ConstellationGit
import SwiftUI

/// Split focus: ↵ or a double-click on a tile. It opens compact, just the transcript and reply box,
/// growing out of the tile; Preview, Diff and Terminal open beside the transcript when you ask
/// (⌘⇧D), widening it. esc goes back. The desktop behind it keeps still; ⇥ moves among its own
/// controls.
struct SessionView: View {
    @Environment(AppModel.self) private var model
    let session: Session
    /// Set when it's a tile in the split screen, which has a compact header and no pane beside it
    /// until it's zoomed.
    var gridTile: GridTileRole?
    @State private var feed = TranscriptFeed()

    /// Where the panel sits in a container of `size`: a chat column, or wide enough for a pane
    /// beside it. Centred, and computed from layout alone so the open and close can animate to it.
    /// A set height, whatever the conversation's length, so the panel never jumps as it grows.
    static func frame(in size: CGSize, showsDetail: Bool) -> CGRect {
        let width = showsDetail ? min(1280, size.width - 128) : min(720, size.width - 64)
        let height = showsDetail ? min(860, size.height - 80) : min(860, (size.height * 0.75).rounded())
        return CGRect(x: ((size.width - width) / 2).rounded(), y: ((size.height - height) / 2).rounded(), width: max(width, 0), height: max(height, 0))
    }

    var body: some View {
        let isCompact = gridTile.map { !$0.isZoomed } ?? false
        let detail = isCompact ? nil : model.sessionDetail
        VStack(spacing: 0) {
            if model.isTriaging, model.openedSessionID == session.id { TriageStrip() }
            if isCompact {
                GridTileHeader(session: session)
            } else {
                header
            }
            HStack(spacing: 0) {
                TranscriptColumn(session: session, transcript: feed.transcript, streaming: model.output(for: session.id).streaming,
                                 takesKeys: gridTile?.isFocused ?? true)
                    .frame(width: detail == nil ? nil : 600)
                if let detail {
                    SessionDetailTabs(session: session, tab: detail, lastWrittenFile: feed.transcript.lastWrittenFile, revision: feed.revision)
                        // An inset well inside the panel, its corners concentric with the panel's.
                        .clipShape(.rect(cornerRadius: Radius.inner, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Radius.inner, style: .continuous).strokeBorder(Palette.text.opacity(0.09)))
                        .padding([.trailing, .bottom], 8)
                        // On the spring that widens the panel for it, so it never shows squeezed.
                        .transition(.opacity)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .panelSurface()
        .onDrop(of: AppModel.droppableTypes, isTargeted: nil) { providers in
            model.acceptDrop(providers, onto: session.id, onTile: false)
        }
        .overlay {
            if let request = model.rewindRequest, request.sessionID == session.id {
                ZStack {
                    Color.black.opacity(0.35).onTapGesture { model.rewindRequest = nil }
                    RewindConfirmation(request: request)
                }
                .clipShape(.rect(cornerRadius: PanelSurface.cornerRadius, style: .continuous))
            }
        }
        .task(id: session.id) { await feed.load(session.id, services: model.services) }
        .task(id: model.output(for: session.id).lines) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await feed.load(session.id, services: model.services)
        }
    }

    private var header: some View {
        SessionViewHeader(session: session, revision: feed.revision)
    }
}

/// The session view's ``PanelHeader``: the title and branch on the left, and on the right the one
/// git step that fits now, the next blocked session, the panes toggle, a … menu with everything
/// else, and Back.
private struct SessionViewHeader: View {
    @Environment(AppModel.self) private var model
    let session: Session
    /// Changes as the transcript reloads, so the git step follows the agent's work.
    let revision: Int
    @State private var pushState: PushState?

    var body: some View {
        let project = model.project(session.projectID)
        PanelHeader {
            RunGlyph(runState: session.runState)
            if let project { ProjectMark(project: project) }
            Text(session.title)
                .font(.ui(13, weight: .medium))
                .foregroundStyle(Palette.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .onTapGesture(count: 2) { model.perform(.sessionRename, on: .session(session.id)) }
                .help("Double-click to rename")
            if let branch = branch(project) {
                Text(branch)
                    .font(.ui(12))
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 160, alignment: .leading)
                    .layoutPriority(-1)
            }
        } trailing: {
            gitStep
            if let next = model.nextBlockedTitle(after: session.id) {
                Button { model.perform(.focusNextBlocked) } label: {
                    QuietChip(title: "Next: \(next)", isMenu: false)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: 200)
                .help("Open the next session that needs you")
            }
            DetailToggle(isShowing: model.sessionDetail != nil) { model.perform(.sessionDetail) }
            if model.canPerform(.gridAdd, on: .session(session.id)) {
                Button { model.perform(.gridAdd, on: .session(session.id)) } label: {
                    Image(systemName: "rectangle.split.2x1").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(IconButtonStyle())
                .help("Add to grid" + (model.binding(for: .gridAdd).map { " (\($0.label))" } ?? ""))
                .accessibilityLabel("Add to grid")
            }
            PanelMaximiseButton()
            overflowMenu
            PanelBackButton()
        }
        .task(id: TaskKey(sessionID: session.id, revision: revision)) {
            let (git, worktree, base) = (model.services.git, session.worktreePath, session.baseBranch)
            pushState = try? await git.pushState(of: worktree, base: base)
        }
    }

    private struct TaskKey: Hashable {
        let sessionID: UUID
        let revision: Int
    }

    private func branch(_ project: Project?) -> String? {
        guard !session.branch.isEmpty, session.branch != project?.defaultBranch else { return nil }
        return session.branch.replacingOccurrences(of: "constellation/", with: "")
    }

    /// The one git step that makes sense now: the open PR, else Commit with changes, Push with
    /// commits to send, Create PR once pushed. The others stay in the … menu.
    @ViewBuilder private var gitStep: some View {
        if let pullRequest = session.pullRequest {
            Button { NSWorkspace.shared.open(pullRequest.url) } label: {
                QuietChip(title: "PR #\(pullRequest.number)", systemImage: "arrow.triangle.pull", isMenu: false, isProminent: true)
            }
            .buttonStyle(.plain)
            .help("Open PR #\(pullRequest.number) on GitHub")
        } else if let action = suggestedGitAction {
            Button { model.perform(action.actionID, on: .session(session.id)) } label: {
                QuietChip(title: action.title(for: session), systemImage: action.systemImage, isMenu: false, isProminent: true)
            }
            .buttonStyle(.plain)
        }
    }

    private var suggestedGitAction: GitAction? {
        guard let pushState else { return nil }
        if pushState.uncommittedFiles > 0 { return .commit }
        // With no remote to push to, a worktree's commits land locally instead.
        if pushState.unpushedCommits > 0 { return pushState.hasOrigin || !session.usesWorktree ? .push : .merge }
        if pushState.hasUpstream, pushState.hasOrigin, pushState.branch != session.baseBranch { return .pullRequest }
        return nil
    }

    private var overflowMenu: some View {
        let item = TileItem.session(session.id)
        return PanelOverflowMenu(help: "More: git, editor, fork, rename, archive") {
            GitActionsMenu(session: session)
            Divider()
            ActionButton(.sessionOpenInEditor, on: item)
            Menu("Open in") { OpenInEditorItems(sessionID: session.id) }
            ActionButton(.sessionTerminal, on: item)
            ActionButton(.sessionDetail, on: item)
            ActionButton(.gridAdd, on: item)
            ActionButton(.gridRemove, on: item)
            Divider()
            ActionButton(.sessionFork, on: item)
            ActionButton(.sessionRewind, on: item)
            ActionButton(.sessionRename, on: item)
            Divider()
            ActionButton(.sessionCopyBranch, on: item)
            ActionButton(.sessionCopyPath, on: item)
            Divider()
            ActionButton(.sessionInterrupt, on: item)
            ActionButton(.sessionStop, on: item)
            ActionButton(.sessionArchive, on: item)
            if let summary = model.usage[session.id]?.tooltip {
                Divider()
                Text(summary)
            }
        }
    }
}

/// While triaging, a quiet line over the header: how far through you are, and the keys to stop
/// or skip.
private struct TriageStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let progress = model.triageProgress {
            HStack(spacing: 6) {
                Text("\(progress.position) of \(progress.total) · \(key(.back, or: "esc")) to stop")
                    .monospacedDigit()
                Spacer(minLength: 8)
                step(.triagePrevious, systemImage: "chevron.left", help: "Back to the one before")
                step(.triageNext, systemImage: "chevron.right", help: "Skip to the next")
            }
            .font(.ui(11))
            .foregroundStyle(Palette.textTertiary)
            .padding(.leading, 16)
            .padding(.trailing, 10)
            .frame(height: 24)
            .background(Palette.text.opacity(0.03))
        }
    }

    private func key(_ id: ActionID, or fallback: String) -> String {
        model.binding(for: id)?.label ?? fallback
    }

    private func step(_ id: ActionID, systemImage: String, help: String) -> some View {
        Button { model.perform(id) } label: {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 18, height: 18)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!model.canPerform(id))
        .help("\(help) (\(key(id, or: "")))")
    }
}

/// The quiet header button that opens and closes Preview, Diff and Terminal.
private struct DetailToggle: View {
    @Environment(AppModel.self) private var model
    let isShowing: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: "sidebar.right")
                .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(IconButtonStyle(isOn: isShowing))
        .help(help)
    }

    private var help: String {
        let action = isShowing ? "Hide preview, diff and terminal" : "Show preview, diff and terminal"
        guard let binding = model.binding(for: .sessionDetail) else { return action }
        return "\(action) (\(binding.strokes.map(\.label).joined(separator: " ")))"
    }
}

/// The stored events for one session, rebuilt into a transcript. Live events reach the store within
/// a quarter second, so the view reloads shortly after each new line on the tile.
@Observable
@MainActor
final class TranscriptFeed {
    private(set) var transcript = Transcript()
    /// Bumps on every load, so the preview and diff refresh alongside the transcript.
    private(set) var revision = 0

    func load(_ id: UUID, services: AppServices) async {
        let (store, recorder) = (services.store, services.recorder)
        try? await recorder.flush()
        let events = await Task.detached { (try? store.events(for: id)) ?? [] }.value
        guard !Task.isCancelled else { return }
        let transcript = Transcript(events.map(\.event))
        if transcript != self.transcript { self.transcript = transcript }
        revision += 1
    }
}

private struct TranscriptColumn: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let transcript: Transcript
    let streaming: String
    /// False for a split screen tile that isn't focused, whose reply box never takes the keys itself.
    var takesKeys = true

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        let shown = transcript.entries.filter(\.isShown)
                        ForEach(shown) { entry in
                            TranscriptRow(entry: entry, provider: session.provider, isSettled: entry.id != shown.last?.id)
                                .modifier(MessageActions(session: session, transcript: transcript, entry: entry))
                        }
                        if let last = LiveOutput.lastLine(of: streaming) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                BrailleSpinner()
                                Text(last).font(.ui(14)).foregroundStyle(Palette.textSecondary)
                            }
                        } else if session.runState == .working {
                            BrailleSpinner()
                        }
                        if let ask = session.nextAsk, !ask.isPermission {
                            InlineAsk(ask: ask)
                                .id(ask.id)
                        }
                        Color.clear.frame(height: 1).id(Self.bottom)
                    }
                    .padding(24)
                }
                // A short chat reads from the top; a long one opens, and stays, at its latest message.
                .defaultScrollAnchor(.top, for: .alignment)
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                .onChange(of: transcript.entries.count) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
                .onChange(of: session.nextAsk?.id) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
            }
            VStack(alignment: .leading, spacing: 12) {
                if let ask = session.nextAsk, case .permission(let permission) = ask.kind {
                    PermissionDock(ask: ask, permission: permission)
                }
                if case .failed(let reason) = session.runState {
                    // Not a notice in the conversation: the reason and Retry sit with the reply box.
                    FailureLine(session: session, reason: reason)
                }
                // Not for a permission, whose ⌥ keys a focused field would type; a question's answers take ↑↓ ↵ there.
                ChatComposer(session: session, focusOnAppear: takesKeys && (session.nextAsk.map { !$0.isPermission } ?? true))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    private static let bottom = "bottom"
}

/// Retry, what went wrong in plain words, and the error as it came behind Details, to read or copy.
private struct FailureLine: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let reason: FailureReason
    @State private var showsDetails = false

    var body: some View {
        let raw = session.failureMessage
        let words = FailureWords.summary(raw.flatMap(LiveOutput.lastLine(of:)), reason: reason)
        HStack(spacing: 10) {
            TileAction(title: "Retry", systemImage: "arrow.clockwise", key: "⌘R") {
                model.perform(.sessionRetry, on: .session(session.id))
            }
            Text(words).font(.ui(12)).foregroundStyle(Palette.error).lineLimit(2)
            Spacer(minLength: 4)
            if let raw, raw != words {
                Button("Details") { showsDetails.toggle() }
                    .buttonStyle(ConstellationButtonStyle(weight: .quiet, height: 22))
                    .popover(isPresented: $showsDetails, arrowEdge: .top) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("The error as it came").font(.ui(12, weight: .medium)).foregroundStyle(Palette.textSecondary)
                                Spacer()
                                CopyButton(text: raw, help: "Copy the error")
                            }
                            ScrollView {
                                Text(raw).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Palette.text)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 220)
                        }
                        .padding(14)
                        .frame(width: 420)
                    }
            }
        }
        .padding(.leading, 4)
    }
}

/// A permission the agent is waiting on, docked on the reply box: the question, what it would
/// run and the answers as one card, lit warmly from its top edge as a waiting tile is, with no
/// outline. Replying in the box below declines it instead.
private struct PermissionDock: View {
    let ask: Ask
    let permission: PermissionAsk

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 12) {
            PermissionDetail(permission: permission, codeHeight: 160)
            ChoiceButtons(ask: ask, height: 28)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            shape.fill(Palette.card)
                .overlay(alignment: .top) {
                    EllipticalGradient(colors: [Palette.ask.opacity(0.22), .clear], center: .top, startRadiusFraction: 0, endRadiusFraction: 0.75)
                        .frame(height: 72)
                }
                .clipShape(shape)
                .shadow(color: .black.opacity(0.25), radius: 12, y: -4)
        }
        .overlay(shape.strokeBorder(Palette.edge))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Permission needed")
    }
}

/// A question or secret the agent is waiting on, as part of its reply rather than in a box: the
/// reply box offers the answers (`ChatComposer`). Several questions, or one with many answers,
/// keep their full form here.
/// Permissions dock on the reply box instead (`PermissionDock`).
private struct InlineAsk: View {
    let ask: Ask

    var body: some View {
        switch ask.kind {
        case .question(let question) where !ask.choices.isEmpty:
            if let item = question.questions.first { AskText(header: item.header, text: item.prompt) }
        case .secret(let secret):
            AskText(header: "", text: secret.reason.isEmpty ? "It needs \(secret.name)." : "\(secret.reason) It needs \(secret.name).")
        default:
            AskForm(ask: ask, codeHeight: 360)
        }
    }
}

/// The agent's question in its own words, as the end of its reply.
private struct AskText: View {
    let header: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !header.isEmpty {
                Text(header.uppercased()).font(.ui(11, weight: .medium)).tracking(0.5).foregroundStyle(Palette.textTertiary)
            }
            Text(text).font(.ui(14, weight: .medium)).foregroundStyle(Palette.text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

private struct TranscriptRow: View {
    let entry: Transcript.Entry
    var provider: Provider = .claudeCode
    var isSettled = false

    var body: some View {
        switch entry {
        case .user(_, let text, let attachments):
            VStack(alignment: .trailing, spacing: 6) {
                if !attachments.isEmpty {
                    AttachmentRow(attachments: attachments)
                        .frame(maxWidth: 352)
                        .fixedSize(horizontal: attachments.count <= 4, vertical: false)
                }
                if !text.isEmpty {
                    MessageBubble(text: text, provider: provider)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant(_, let text):
            MarkdownView(markdown: text)
        case .tools(_, let steps):
            ToolTrace(steps: steps, isSettled: isSettled)
        case .outcome:
            // The result shows as the chat's state (its icon and the tile), not as a notice in the conversation.
            EmptyView()
        case .failure(_, let message):
            Text("\(Glyph.failed) \(message)")
                .font(.ui(13))
                .foregroundStyle(Palette.error)
                .textSelection(.enabled)
        case .interrupted:
            Text("Interrupted").font(.ui(13)).foregroundStyle(Palette.textTertiary)
        case .note(_, let text):
            Text(text).font(.ui(13)).foregroundStyle(Palette.textTertiary)
        }
    }
}

private extension Transcript.Entry {
    /// A run made only of Constellation's own bookkeeping calls shows nothing, so it takes no row.
    var isShown: Bool {
        switch self {
        case .tools(_, let steps): steps.contains { $0.call.phrase != nil }
        case .outcome, .failure: false
        default: true
        }
    }
}
