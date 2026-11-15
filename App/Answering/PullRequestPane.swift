import ConstellationCore
import ConstellationGitHub
import SwiftUI

/// The session view's PR pane: every check with its outcome, and what reviewers wrote, fetched
/// through `gh` when it opens. Either can go to the agent: the failing checks' logs, or the
/// comments, land in the composer for you to send.
struct PullRequestPane: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let pullRequest: PullRequestInfo
    @State private var details: Result<PullRequestDetails, Error>?
    @State private var isSending = false
    @State private var refresh = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch details {
                case nil:
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                case .failure(let error):
                    Text("Couldn't read PR #\(pullRequest.number) with gh: \(Self.describe(error))")
                        .font(.ui(12)).foregroundStyle(Palette.textTertiary)
                case .success(let details):
                    checks(details)
                    comments(details)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: "\(pullRequest.number)-\(pullRequest.checks?.passed ?? -1)-\(refresh)") {
            guard let repository = repository else { return }
            do {
                details = .success(try await PullRequestDetails.fetch(number: pullRequest.number, repository: repository))
            } catch {
                details = .failure(error)
            }
        }
    }

    private var repository: GitHubRepository? {
        let parts = pullRequest.url.pathComponents
        guard parts.count >= 3 else { return nil }
        return GitHubRepository(owner: parts[1], name: parts[2])
    }

    // MARK: Checks

    @ViewBuilder private func checks(_ details: PullRequestDetails) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionLabel(details.checks.isEmpty ? "No checks" : "Checks")
                Spacer()
                Button { refresh += 1 } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundStyle(Palette.textTertiary).help("Fetch again")
                if !details.failing.isEmpty {
                    Button(isSending ? "Reading logs…" : "Send failures to chat") { sendFailures(details.failing) }
                        .buttonStyle(PaneButtonStyle())
                        .disabled(isSending)
                        .help("Puts the failing checks' logs in the composer, asking the agent to fix them")
                }
            }
            let skipped = details.checks.filter { $0.outcome == .skipping }
            ForEach(details.checks.filter { $0.outcome != .skipping }) { check in
                HStack(spacing: 8) {
                    CheckGlyph(outcome: check.outcome)
                    Text(check.name).font(.ui(13)).foregroundStyle(Palette.text).lineLimit(1)
                    if !check.workflow.isEmpty {
                        Text(check.workflow).font(.ui(12)).foregroundStyle(Palette.textTertiary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if let link = check.link {
                        Button { NSWorkspace.shared.open(link) } label: { Image(systemName: "arrow.up.right.square") }
                            .buttonStyle(.plain).foregroundStyle(Palette.textTertiary).help("Open on GitHub")
                    }
                }
                .frame(height: 22)
            }
            if !skipped.isEmpty {
                HStack(spacing: 8) {
                    CheckGlyph(outcome: .skipping)
                    Text("\(skipped.count) skipped").font(.ui(12)).foregroundStyle(Palette.textTertiary)
                }
                .frame(height: 22)
                .help(skipped.map(\.name).joined(separator: "\n"))
            }
        }
    }

    // MARK: Comments

    @ViewBuilder private func comments(_ details: PullRequestDetails) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(details.comments.isEmpty ? "No review comments" : "Review")
                Spacer()
                if !details.comments.isEmpty {
                    Button("Send comments to chat") { sendComments(details.comments) }
                        .buttonStyle(PaneButtonStyle())
                        .help("Puts the review comments in the composer, asking the agent to address them")
                }
            }
            ForEach(details.comments) { comment in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(comment.author).font(.ui(12, weight: .medium)).foregroundStyle(Palette.text)
                        if let verdict = Self.verdict(comment.verdict) {
                            Text(verdict.text).font(.ui(11)).foregroundStyle(verdict.color)
                        }
                        if let place = Self.place(comment) {
                            Text(place).font(.mono(11)).foregroundStyle(Palette.textTertiary).lineLimit(1).truncationMode(.head)
                        }
                    }
                    if !comment.body.isEmpty {
                        Text(Self.rendered(comment.body))
                            .font(.ui(13))
                            .lineLimit(10)
                            .foregroundStyle(Palette.textSecondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: Sending

    private func sendFailures(_ failing: [PullRequestDetails.Check]) {
        guard let repository else { return }
        isSending = true
        Task {
            var sections: [String] = []
            // ponytail: the first three failures' logs; more would bury the agent's context.
            for check in failing.prefix(3) {
                let log = (try? await PullRequestDetails.failureLog(of: check, repository: repository)) ?? "(no log; see \(check.link?.absoluteString ?? "GitHub"))"
                sections.append("### \(check.name)\n```\n\(log)\n```")
            }
            let names = failing.map(\.name).joined(separator: ", ")
            put("CI is failing on PR #\(pullRequest.number) (\(names)). Find the cause and fix it.\n\n" + sections.joined(separator: "\n\n"))
            isSending = false
        }
    }

    private func sendComments(_ comments: [PullRequestDetails.Comment]) {
        let lines = comments.map { comment in
            let place = Self.place(comment).map { " on `\($0)`" } ?? ""
            let verdict = Self.verdict(comment.verdict).map { " (\($0.text.lowercased()))" } ?? ""
            return "- \(comment.author)\(verdict)\(place): \(comment.body)"
        }
        put("Address the review comments on PR #\(pullRequest.number):\n\n" + lines.joined(separator: "\n"))
    }

    /// Into the composer, after anything already there, for you to read and send.
    private func put(_ text: String) {
        model.updateDraft(session.id) { draft in
            draft.text = draft.text.isEmpty ? text : draft.text + "\n\n" + text
        }
        model.notice = "Added to the message for \u{201C}\(session.title)\u{201D}. ↵ sends it."
    }

    // MARK: Text

    /// Inline markdown, without the HTML bots leave or the heading marks Text can't draw.
    private static func rendered(_ body: String) -> AttributedString {
        let text = body
            .replacing(/<!--[\s\S]*?-->/, with: "")
            .replacing(/<[^>]+>/, with: "")
            .replacing(/(?m)^#{1,6} +/, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    private static func place(_ comment: PullRequestDetails.Comment) -> String? {
        guard let path = comment.path else { return nil }
        return comment.line.map { "\(path):\($0)" } ?? path
    }

    private static func verdict(_ state: String?) -> (text: String, color: Color)? {
        switch state {
        case "CHANGES_REQUESTED": ("Changes requested", Palette.ask)
        case "APPROVED": ("Approved", Palette.done)
        default: nil
        }
    }

    private static func describe(_ error: Error) -> String {
        if let failure = error as? PullRequestDetails.Failure { return failure.message }
        return error.localizedDescription
    }
}

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.ui(12, weight: .medium)).foregroundStyle(Palette.textTertiary)
    }
}

private struct CheckGlyph: View {
    let outcome: PullRequestDetails.Check.Outcome

    var body: some View {
        let (symbol, color): (String, Color) = switch outcome {
        case .fail: ("xmark.circle.fill", Palette.error)
        case .pending: ("circle.dotted", Palette.working)
        case .pass: ("checkmark.circle.fill", Palette.done)
        case .skipping, .cancel: ("minus.circle", Palette.textTertiary)
        }
        Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(color).frame(width: 14)
            .accessibilityLabel(outcome.rawValue)
    }
}

private struct PaneButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ui(12, weight: .medium))
            .foregroundStyle(isEnabled ? Palette.text : Palette.textTertiary)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Palette.text.opacity(configuration.isPressed ? 0.16 : 0.08), in: .capsule)
            .contentShape(.capsule)
    }
}
