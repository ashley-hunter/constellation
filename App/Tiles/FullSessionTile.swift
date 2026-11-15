import ConstellationCore
import SwiftUI

/// A full tile: one continuous surface with the title, a line or two saying the most useful thing
/// in plain words, and the state with how long ago. Spacing separates them, not rules.
///
/// Urgency shows as colour, never size: needing you lights the edge amber with a soft halo, failed
/// the same in red, working sends a light slowly round the edge, done and unseen puts a green dot
/// at the end of the title, and seen work goes quiet.
struct FullSessionTile: View {
    @Environment(AppModel.self) private var model
    @Environment(\.cardSize) private var size
    let session: Session
    let project: Project?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TileTitleBar(session: session, project: project)
            TileSummary(session: session, output: model.output(for: session.id), hasPullRequest: session.pullRequest != nil)
            Spacer(minLength: 0)
            if let pullRequest = session.pullRequest {
                PullRequestRow(pullRequest: pullRequest)
            }
            TileFooter(session: session, project: project)
        }
        .frame(width: size.width, height: size.height)
        .panelSurface(.card, edge: RunStateStyle.border(for: session.runState, lifecycle: session.lifecycle))
        .background {
            if let halo = RunStateStyle.halo(for: session.runState) {
                RoundedRectangle(cornerRadius: PanelSurface.cornerRadius, style: .continuous)
                    .fill(Palette.popover)
                    .shadow(color: halo.opacity(0.3), radius: 9)
            }
        }
        .overlay {
            if RunStateStyle.isWorking(session.runState) { TravellingEdge() }
        }
        .saturation(RunStateStyle.isQuiet(session) ? 0.6 : 1)
    }
}

/// Glyph, swatch and name, with a dot while unseen; the name gets all the width, the branch going
/// in the footer.
struct TileTitleBar: View {
    let session: Session
    let project: Project?

    var body: some View {
        HStack(spacing: 8) {
            RunGlyph(runState: session.runState)
            if let project { ProjectMark(project: project) }
            Text(session.title)
                .font(.ui(13, weight: .medium))
                .foregroundStyle(RunStateStyle.isQuiet(session) ? Palette.textSecondary : Palette.text)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if RunStateStyle.isUnseenDone(session) {
                Circle().fill(Palette.done).frame(width: 6, height: 6)
                    .accessibilityLabel("Done, not seen")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .frame(height: TileMetrics.titleBarHeight)
        .contentShape(.rect)
    }
}

/// The most useful thing about the session now, in words: what it found or did when done, what
/// it is doing while working, its question when blocked, the error when failed.
struct TileSummary: View {
    let session: Session
    let output: LiveOutput
    let hasPullRequest: Bool

    var body: some View {
        let (primary, secondary) = lines
        // A waiting card's question is drawn with its answers (`InPlaceAnswer`), which size it to
        // the room they leave.
        let isAsking = session.runState == .blocked && session.nextAsk != nil
        VStack(alignment: .leading, spacing: 4) {
            Text(primary)
                .font(.ui(13))
                .foregroundStyle(primaryColor)
                .lineLimit(secondary == nil && !hasPullRequest ? 3 : 2)
            if let secondary, !hasPullRequest {
                Text(secondary)
                    .font(.ui(12))
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .opacity(isAsking ? 0 : 1)
    }

    var lines: (String, String?) {
        let streaming = LiveOutput.lastLine(of: output.streaming)
        switch session.runState {
        case .draft:
            return ("Draft", nil)
        case .preparing(let stage):
            return (RunStateStyle.stageLabel(stage).prefix(1).uppercased() + RunStateStyle.stageLabel(stage).dropFirst() + "…", nil)
        case .working:
            return (output.activity ?? streaming ?? "Thinking…", output.activity == nil ? nil : streaming)
        case .blocked:
            return (session.nextAsk?.kind.headline ?? "Needs you", nil)
        case .failed(let reason):
            // In plain words here; the session view keeps the raw error.
            let error = session.failureMessage.flatMap(LiveOutput.lastLine(of:))
                ?? output.lines.last { $0.tone == .error }?.text.trimmingCharacters(in: .whitespaces)
            return (FailureWords.summary(error, reason: reason), nil)
        case .done:
            if let outcome = session.outcome {
                return (outcome.summary, output.lastReply == outcome.summary ? nil : output.lastReply)
            }
            return (output.lastReply ?? "Done", nil)
        case .interrupted:
            // The footer already says Interrupted; without a reply, say how far it got.
            if let reply = output.lastReply { return (reply, nil) }
            let files = session.filesTouched.count
            return ("Stopped before it replied.", files == 0 ? "Resume to carry on." : "Changed \(files) file\(files == 1 ? "" : "s") so far. Resume to carry on.")
        }
    }

    var primaryColor: Color {
        switch session.runState {
        case .failed: Palette.error
        case .blocked: Palette.ask
        default: Palette.text
        }
    }
}

struct PullRequestRow: View {
    let pullRequest: PullRequestInfo

    var body: some View {
        // "#14927 · CI 11/12 ✕", the state only when it isn't open, the review only when it asks
        // for changes.
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.pull").font(.system(size: 10)).foregroundStyle(Palette.textTertiary)
                .padding(.trailing, 4)
            Text(verbatim: "#\(pullRequest.number)\(stateLabel.map { " \($0)" } ?? "")").foregroundStyle(Palette.textSecondary)
            if let checks = pullRequest.checks {
                Text(verbatim: "· CI \(checks.passed)/\(checks.total) \(checkGlyph(checks))")
                    .foregroundStyle(checks.state == .failure || checks.state == .error ? Palette.error : Palette.textSecondary)
            }
            if pullRequest.reviewDecision == .changesRequested {
                Text("· Changes requested").foregroundStyle(Palette.ask)
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .font(.ui(12)).monospacedDigit()
        .padding(.horizontal, 12)
        .frame(height: 22)
        .contentShape(.rect)
        .onTapGesture { NSWorkspace.shared.open(pullRequest.url) }
        .help("Open PR #\(pullRequest.number) on GitHub")
    }

    private var stateLabel: String? {
        if pullRequest.isDraft { return "draft" }
        return pullRequest.state == .open ? nil : pullRequest.state.rawValue
    }

    private func checkGlyph(_ checks: CheckSummary) -> String {
        switch checks.state {
        case .success: Glyph.done
        case .failure, .error: Glyph.failed
        case .pending, .expected: Glyph.brailleFrames[2]
        }
    }
}
