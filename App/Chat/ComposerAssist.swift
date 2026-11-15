import ConstellationCore
import Foundation
import Observation

/// What the composer's `/` and `@` menus and prompt history keep between keystrokes: loaded command
/// and file lists, the selected row, and each session's place in its history walk.
@Observable
@MainActor
final class ComposerAssist {
    struct Loaded<Value> {
        var value: Value
        var loadedAt: Date

        func isFresh(for interval: TimeInterval) -> Bool {
            Date().timeIntervalSince(loadedAt) < interval
        }
    }

    /// By provider and worktree.
    var commands: [String: Loaded<[SlashCommand]>] = [:]
    /// By worktree path.
    var files: [String: Loaded<[String]>] = [:]
    /// The highlighted row of each session's open menu.
    var selection: [UUID: Int] = [:]
    /// The draft text each session's menu was closed at with esc. It stays closed until the text changes.
    var dismissedAt: [UUID: String] = [:]

    /// Each project's earlier prompts, newest first, once read from the store.
    @ObservationIgnored var history: [UUID: [String]] = [:]
    /// Each session's ↑ walk through its project's history.
    @ObservationIgnored var walks: [UUID: PromptHistoryWalk] = [:]
    @ObservationIgnored var loading: Set<String> = []
    /// The last ranking, since the menu asks for it on every render and keystroke.
    @ObservationIgnored var lastRanking: (key: String, items: [ComposerMenuItem])?
}

/// A row in the `/` or `@` menu.
struct ComposerMenuItem: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let badge: String?
    /// What replaces the `/…` or `@…` being typed.
    let insertion: String
}

/// The menu open on a composer: what is being completed and the rows that match.
struct ComposerMenu {
    let token: ComposerToken
    let items: [ComposerMenuItem]
    let isLoading: Bool
}

/// esc and tab while a composer's menu is open.
enum ComposerMenuKey {
    case dismiss, accept

    init?(_ key: String) {
        switch key {
        case "escape": self = .dismiss
        case "tab": self = .accept
        default: return nil
        }
    }
}
