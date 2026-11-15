import ConstellationCore
import SwiftUI

/// The panes that can open beside a session's transcript.
enum SessionDetail: String, CaseIterable, Hashable {
    case preview, diff, terminal, pullRequest

    var title: String {
        switch self {
        case .preview: "Preview"
        case .diff: "Diff"
        case .terminal: "Terminal"
        case .pullRequest: "PR"
        }
    }
}

/// Preview, Diff, Terminal and, once it has one, its PR beside the transcript, shown when you ask
/// for them.
struct SessionDetailTabs: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let tab: SessionDetail
    let lastWrittenFile: String?
    /// Changes whenever the transcript reloads, so previews follow the agent's writes.
    let revision: Int

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(SessionDetail.allCases.filter { $0 != .pullRequest || session.pullRequest != nil }, id: \.self) { item in
                    Button(item.title) { model.sessionDetail = item }
                        .buttonStyle(TabButtonStyle(isSelected: tab == item))
                }
                Spacer(minLength: 12)
                Text(caption)
                    .font(.ui(12)).monospacedDigit()
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Group {
                switch tab {
                case .preview:
                    if let server { ServerPreview(session: session, url: server) } else { FilePreview(file: fileURL, revision: revision) }
                case .diff: WorktreeDiff(session: session, lastWrittenPath: lastWrittenPath, revision: revision)
                case .terminal: SessionTerminalPane(sessionID: session.id)
                case .pullRequest:
                    if let pullRequest = session.pullRequest { PullRequestPane(session: session, pullRequest: pullRequest) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Palette.surfaceSunken.opacity(0.6))
    }

    /// The dev server a shell in the worktree is running, which Preview shows over the last file.
    private var server: URL? {
        model.server(forSession: session.id)
    }

    private var fileURL: URL? {
        guard let lastWrittenFile else { return nil }
        if lastWrittenFile.hasPrefix("/") { return URL(filePath: lastWrittenFile) }
        return session.worktreePath.appending(path: lastWrittenFile)
    }

    /// The last written file relative to the worktree, as the diff names it.
    private var lastWrittenPath: String? {
        guard let lastWrittenFile else { return nil }
        guard lastWrittenFile.hasPrefix("/") else { return lastWrittenFile }
        let root = session.worktreePath.standardizedFileURL.path(percentEncoded: false)
        let file = URL(filePath: lastWrittenFile).standardizedFileURL.path(percentEncoded: false)
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return file.hasPrefix(prefix) ? String(file.dropFirst(prefix.count)) : nil
    }

    private var caption: String {
        switch tab {
        case .preview: server.map(Self.address) ?? lastWrittenFile ?? ""
        case .diff: "against \(session.baseBranch)"
        case .terminal:
            session.worktreePath.path(percentEncoded: false)
                + (model.worktreePort(for: session.worktreePath, projectID: session.projectID).map { "  ·  port \($0)" } ?? "")
        case .pullRequest: session.pullRequest.map { "#\($0.number) \($0.isDraft ? "draft" : $0.state.rawValue)" } ?? ""
        }
    }
}

extension SessionDetailTabs {
    /// "localhost:4127", as the Preview header names a server.
    static func address(_ url: URL) -> String {
        guard let host = url.host() else { return url.absoluteString }
        return url.port.map { "\(host):\($0)" } ?? host
    }
}

/// The page a shell in the session's worktree is serving, in a web view kept by the browser host
/// under the session's id, so it keeps its place while you switch tabs.
private struct ServerPreview: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let url: URL

    var body: some View {
        BrowserSurface(browser: Terminal(id: session.id, projectID: session.projectID, workingDirectory: session.worktreePath, title: session.title, url: url))
            .task(id: url) {
                // A server started again on another port, or this one's first page.
                guard let view = model.browserHost.webView(session.id), view.url != nil || !view.isLoading else { return }
                if view.url?.host() != url.host() || view.url?.port != url.port { model.browserHost.load(url, in: session.id) }
            }
    }
}

private struct TabButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ui(13))
            .foregroundStyle(isSelected ? Palette.text : Palette.textSecondary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(isSelected ? Palette.rowSelected : .clear, in: .capsule)
            .contentShape(.rect)
    }
}

/// The file the agent last wrote: markdown rendered, anything else as numbered lines.
private struct FilePreview: View {
    nonisolated static let byteLimit = 512 * 1024

    let file: URL?
    let revision: Int
    @State private var contents: Result<String, PreviewError>?

    enum PreviewError: Error {
        case unreadable, tooLarge
    }

    var body: some View {
        Group {
            switch (file, contents) {
            case (nil, _):
                Placeholder(text: "Nothing written yet. The last file the agent writes shows here.")
            case (_, nil):
                Color.clear
            case (_, .failure(.tooLarge)?):
                Placeholder(text: "Too large to preview.")
            case (_, .failure?):
                Placeholder(text: "Couldn't read this file. It may have been moved or deleted.")
            case (let file?, .success(let text)?):
                if ["md", "markdown"].contains(file.pathExtension.lowercased()) {
                    ScrollView {
                        MarkdownView(markdown: text)
                            .frame(maxWidth: 640, alignment: .leading)
                            .padding(.horizontal, 48)
                            .padding(.vertical, 32)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    CodeBlock(text, isDiff: false, maxHeight: .infinity, isFramed: false)
                        .padding(.horizontal, 8)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
        }
        .task(id: TaskKey(file: file, revision: revision)) {
            guard let file else { return }
            contents = await Task.detached { Self.read(file) }.value
        }
    }

    private struct TaskKey: Hashable {
        let file: URL?
        let revision: Int
    }

    private nonisolated static func read(_ file: URL) -> Result<String, PreviewError> {
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return .failure(.unreadable) }
        guard size <= byteLimit else { return .failure(.tooLarge) }
        guard let data = try? Data(contentsOf: file) else { return .failure(.unreadable) }
        return .success(String(decoding: data, as: UTF8.self))
    }
}

/// The worktree's diff against the merge base with the session's base branch.
private struct WorktreeDiff: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let lastWrittenPath: String?
    let revision: Int
    @State private var diff: Result<DiffDisplay, Error>?

    var body: some View {
        Group {
            switch diff {
            case nil:
                Color.clear
            case .failure(let error)?:
                Placeholder(text: "Couldn't diff the worktree: \(error.localizedDescription)")
            case .success(let display)? where display.diff.files.isEmpty:
                Placeholder(text: "No changes against \(session.baseBranch) yet.")
            case .success(let display)?:
                DiffView(display: display, lastWrittenPath: lastWrittenPath)
            }
        }
        .task(id: revision) {
            let (git, path, base) = (model.services.git, session.worktreePath, session.baseBranch)
            do {
                let text = try await git.unifiedDiff(in: path, against: base)
                diff = .success(await Task.detached { DiffDisplay(text) }.value)
            } catch {
                diff = .failure(error)
            }
        }
    }
}

struct Placeholder: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.ui(13))
            .foregroundStyle(Palette.textTertiary)
            .multilineTextAlignment(.center)
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
