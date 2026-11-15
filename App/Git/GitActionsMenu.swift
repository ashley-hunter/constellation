import ConstellationCore
import SwiftUI

/// Commit, Push, Create PR and Merge as quiet buttons in the session view header.
struct GitActionsButton: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        HStack(spacing: 4) {
            ForEach(GitAction.allCases, id: \.self) { action in
                Button { model.perform(action.actionID, on: .session(session.id)) } label: {
                    Label(action.title(for: session), systemImage: action.systemImage)
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(ConstellationButtonStyle(weight: .quiet, height: 30))
                .help(help(for: action))
            }
        }
    }

    private func help(for action: GitAction) -> String {
        switch action {
        case .commit: "Choose changed files and commit them"
        case .push: "git push -u origin \(session.branch)"
        case .pullRequest: "Push if needed, then open a draft PR with gh"
        case .merge: "Merge \(session.branch) into \(session.baseBranch) locally"
        }
    }
}

/// The same actions in a session tile's context menu.
struct GitActionsMenu: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        ForEach(GitAction.allCases, id: \.self) { action in
            ActionButton(action.actionID, on: .session(session.id), showsIcon: true)
        }
    }
}

extension GitAction {
    var actionID: ActionID {
        switch self {
        case .commit: .gitCommit
        case .push: .gitPush
        case .pullRequest: .gitPullRequest
        case .merge: .gitMerge
        }
    }
}
