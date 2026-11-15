import ConstellationCore
import SwiftUI

/// How a run state reads on tiles and in the sidebar.
enum RunStateStyle {
    static func glyph(for state: RunState) -> String {
        switch state {
        case .draft: Glyph.draft
        case .preparing, .working: Glyph.brailleFrames[2]
        case .blocked: Glyph.blocked
        case .failed: Glyph.failed
        case .done: Glyph.done
        case .interrupted: Glyph.interrupted
        }
    }

    static func color(for state: RunState) -> Color {
        switch state {
        case .draft, .preparing, .working: Palette.textTertiary
        case .blocked: Palette.ask
        case .failed: Palette.error
        case .done: Palette.text
        case .interrupted: Palette.textSecondary
        }
    }

    static func label(for state: RunState) -> String {
        switch state {
        case .draft: "New session"
        case .preparing(let stage): "Preparing: \(stageLabel(stage))"
        case .working: "Working"
        case .blocked: "Needs you"
        case .failed: "Failed"
        case .done: "Done"
        case .interrupted: "Interrupted"
        }
    }

    static func stageLabel(_ stage: LaunchStage) -> String {
        switch stage {
        case .fetch: "fetching"
        case .worktree: "creating worktree"
        case .setup: "running setup"
        case .starting: "starting"
        }
    }

    /// The tile border: the error colour when failed. A blocked tile is lit from above instead
    /// (`StateCue`).
    static func border(for state: RunState, lifecycle: Lifecycle) -> Color {
        switch state {
        case .failed: Palette.error.opacity(0.7)
        case .done where lifecycle == .unseen: .white.opacity(0.22)
        default: Palette.edge
        }
    }

    /// The soft glow round a tile that needs you or has failed.
    static func halo(for state: RunState) -> Color? {
        switch state {
        // Waiting says so on the card itself (`StateCue`, `InPlaceAnswer`), with no halo.
        case .failed: Palette.error
        default: nil
        }
    }

    static func isWorking(_ state: RunState) -> Bool {
        switch state {
        case .preparing, .working: true
        default: false
        }
    }

    /// Finished and not looked at yet: a green dot at the end of the title.
    static func isUnseenDone(_ session: Session) -> Bool {
        session.lifecycle == .unseen && (session.runState == .done || session.runState == .interrupted)
    }

    /// Finished and seen (or settled): slightly desaturated, the title in secondary text. Never
    /// while its PR needs you.
    static func isQuiet(_ session: Session) -> Bool {
        guard session.runState == .done || session.runState == .interrupted, !session.pullRequestNeedsYou else { return false }
        return session.lifecycle != .unseen
    }
}
