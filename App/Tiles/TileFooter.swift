import ConstellationCore
import SwiftUI

extension EnvironmentValues {
    /// The branch the card's pile label names, so its footer needn't say it again.
    @Entry var pileBranch: String?
}

/// State and how long ago on the left, quiet, then the branch when it isn't the project's default
/// or already the pile's name; the keys that act on this tile on the right.
struct TileFooter: View {
    @Environment(AppModel.self) private var model
    @Environment(\.pileBranch) private var pileBranch
    let session: Session
    let project: Project?

    var body: some View {
        HStack(spacing: 8) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(status(at: context.date))
                    .font(.ui(12))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
            }
            .layoutPriority(1)
            if let branch = session.shortBranch(defaultBranch: project?.defaultBranch),
               branch != pileBranch.flatMap({ Session.shortBranch($0, defaultBranch: project?.defaultBranch) }) {
                Text(branch)
                    .font(.ui(12))
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            // The branch gives way first, then the status; the keys never do.
            HStack(spacing: 8) { actions }
                .fixedSize()
                .layoutPriority(2)
        }
        // The pill sits concentric with the card's corner: the card's radius less the pill's.
        .padding(.leading, 12)
        .padding(.trailing, TileAction.cornerInset)
        .frame(height: TileAction.height)
        .padding(.bottom, TileAction.cornerInset)
    }

    @ViewBuilder private var actions: some View {
        switch session.runState {
        case .blocked:
            if let ask = session.nextAsk { AskKeyHints(kind: ask.kind) }
        case .failed:
            TileAction(title: "Retry", systemImage: "arrow.clockwise", key: "⌘R") {
                model.perform(.sessionRetry, on: .session(session.id))
            }
        case .interrupted where model.canResume(session.id):
            TileAction(title: "Resume", systemImage: "play.fill", key: "⌘R") {
                model.perform(.sessionResume, on: .session(session.id))
            }
        default:
            EmptyView()
        }
    }

    private func status(at now: Date) -> String {
        // Finished, but its PR wants you: say why rather than when it finished.
        if session.pullRequestNeedsYou, let pullRequest = session.pullRequest {
            let failing = pullRequest.checks.map { $0.state == .failure || $0.state == .error } ?? false
            return failing ? "CI failing" : "Changes requested"
        }
        let elapsed = session.elapsed(at: now).map { " · " + ElapsedTime.label($0) } ?? ""
        switch session.runState {
        case .draft: return "Draft"
        case .preparing(let stage): return "Preparing · \(RunStateStyle.stageLabel(stage))\(elapsed)"
        case .working: return "Working\(elapsed)"
        case .blocked: return session.nextAsk?.kind.footerLabel ?? "Needs you"
        case .failed(.launch(let stage)): return "Failed at \(stage.rawValue)"
        case .failed(.auth): return "Auth"
        case .failed(.usageLimit): return "Usage limit"
        case .failed: return "Failed"
        case .done: return "Done · \(ElapsedTime.label(now.timeIntervalSince(session.lastActivityAt))) ago"
        case .interrupted: return "Interrupted"
        }
    }

    private var statusColor: Color {
        if session.pullRequestNeedsYou { return Palette.ask }
        return switch session.runState {
        case .blocked: Palette.ask
        case .failed: Palette.error
        default: Palette.textTertiary
        }
    }
}

/// The in-place answer keys for the next ask.
struct AskKeyHints: View {
    let kind: AskKind
    @Environment(\.showsCardKeys) private var showsKeys

    var body: some View {
        if showsKeys { hints }
    }

    @ViewBuilder private var hints: some View {
        switch kind {
        case .permission:
            KeyHint(key: "⌥Y", label: "allow")
            KeyHint(key: "⌥N", label: "deny")
        case .question(let ask):
            let count = ask.questions.count == 1 ? ask.questions[0].options.count : 0
            if count > 0, ask.questions[0].multiSelect == false {
                KeyHint(key: count == 1 ? "⌥1" : "⌥1-\(min(count, 9))", label: "pick")
            } else {
                KeyHint(key: "↵", label: "answer")
            }
        case .secret:
            KeyHint(key: "↵", label: "provide")
        }
    }
}

/// A tile's one footer action, in the Sort UI's quiet style: a small pill with an icon, the label and
/// its key, a soft fill that only lifts on hover, and no hard border.
struct TileAction: View {
    let title: String
    let systemImage: String
    let key: String
    let action: () -> Void
    @Environment(\.showsCardKeys) private var showsKey
    @State private var isHovered = false

    /// The pill's corner radius (a capsule, half its height) and the key box's. The key sits
    /// `pillRadius - keyRadius` in from the pill's end, so the two curves stay concentric.
    static let height: CGFloat = 22
    private static let keyRadius = Radius.key
    /// How far the pill sits from the card's bottom and trailing edges.
    static var cornerInset: CGFloat { PanelSurface.cornerRadius - height / 2 }
    private static var keyInset: CGFloat { height / 2 - keyRadius }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).font(.system(size: 9, weight: .semibold))
                Text(title).font(.ui(12, weight: .medium))
                if showsKey || isHovered {
                    Text(key)
                        .font(.ui(10, weight: .semibold))
                        .foregroundStyle(Palette.textTertiary)
                        .frame(width: 14, height: 14)
                        .background(Palette.text.opacity(0.08), in: .rect(cornerRadius: Self.keyRadius))
                }
            }
            .foregroundStyle(isHovered ? Palette.text : Palette.textSecondary)
            .padding(.leading, 10)
            .padding(.trailing, Self.keyInset)
            .frame(height: Self.height)
            .background(Palette.text.opacity(isHovered ? 0.12 : 0.07), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.constellation, value: isHovered)
        .fixedSize()
    }
}
