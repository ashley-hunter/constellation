import ConstellationCore
import Foundation

/// The models Settings offers as defaults, before a provider's own catalog has loaded.
enum ComposerDraft {
    struct ModelOption: Hashable, Identifiable, Sendable {
        var id: String
        var title: String
    }

    /// Claude Code takes model aliases; an empty Codex model lets the app-server choose its default.
    static func models(for provider: Provider) -> [ModelOption] {
        switch provider {
        case .claudeCode:
            [ModelOption(id: "opus", title: "Opus"), ModelOption(id: "sonnet", title: "Sonnet"), ModelOption(id: "haiku", title: "Haiku")]
        case .codex:
            [ModelOption(id: "", title: "Default")]
        }
    }
}

extension PermissionMode {
    var title: String {
        switch self {
        case .askForEverything: "Ask for everything"
        case .askForRisky: "Ask for risky"
        case .fullAuto: "Full auto"
        }
    }
}
