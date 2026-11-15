import ConstellationCore
import ConstellationGit
import ConstellationStore
import Foundation
import Observation

/// What the Settings window edits, kept in the store's settings table. Loaded once at launch;
/// each change is written straight back.
@Observable
@MainActor
final class AppSettings {
    enum Key {
        static let defaultProvider = "defaultProvider"
        static let defaultModel = "defaultModel"
        static let defaultPermissionMode = "defaultPermissionMode"
        static let defaultNewWorktree = "defaultNewWorktree"
        static let worktreeRoot = "worktreeRoot"
        static let newProjectsFolder = "newProjectsFolder"
        static let editor = "editor"
        static let notifiesWhenBlocked = "notifiesWhenBlocked"
        static let notifiesWhenFailed = "notifiesWhenFailed"
        static let cardsDrift = "cardsDrift"
        static let wigglesForAttention = "wigglesForAttention"
        static let defaultEffort = "defaultEffort"
        static let onboardingCompleted = "onboardingCompleted"
        static let desktopArrangement = "desktopArrangement"
        static let background = "background"
    }

    @ObservationIgnored private let store: Store
    @ObservationIgnored private let git: GitService

    var defaultProvider: Provider {
        didSet {
            save(Key.defaultProvider, defaultProvider.rawValue)
            if !Self.offers(defaultModel, for: defaultProvider) { defaultModel = ComposerDraft.models(for: defaultProvider)[0].id }
            if let defaultEffort, !Self.efforts(for: defaultProvider).contains(defaultEffort) { self.defaultEffort = nil }
        }
    }

    var defaultModel: String {
        didSet { save(Key.defaultModel, defaultModel) }
    }

    var defaultPermissionMode: PermissionMode {
        didSet { save(Key.defaultPermissionMode, defaultPermissionMode.rawValue) }
    }

    /// Whether a new session gets its own worktree, or runs in the main checkout.
    var defaultNewWorktree: Bool {
        didSet { save(Key.defaultNewWorktree, String(defaultNewWorktree)) }
    }

    var cleanupThreshold: CleanupThreshold {
        didSet { save(CleanupSettingKey.threshold, cleanupThreshold.rawValue) }
    }

    /// Nil for `GitService.defaultWorktreesRoot`. New worktrees go here; existing ones stay put.
    var worktreeRoot: URL? {
        didSet {
            save(Key.worktreeRoot, worktreeRoot?.path(percentEncoded: false))
            let (git, root) = (git, effectiveWorktreeRoot)
            Task { await git.setWorktreesRoot(root) }
        }
    }

    /// Where New project makes its folder. Nil for next to the latest project (see
    /// `AppModel.newProjectsRoot`).
    var newProjectsFolder: URL? {
        didSet { save(Key.newProjectsFolder, newProjectsFolder?.path(percentEncoded: false)) }
    }

    /// The editor Open in uses without asking. Set by the last one you picked.
    var editor: Editor? {
        didSet { save(Key.editor, editor?.rawValue) }
    }

    var notifiesWhenBlocked: Bool {
        didSet { save(Key.notifiesWhenBlocked, String(notifiesWhenBlocked)) }
    }

    var notifiesWhenFailed: Bool {
        didSet { save(Key.notifiesWhenFailed, String(notifiesWhenFailed)) }
    }

    /// Piles at rest sway a point or two, very slowly, so the desktop doesn't sit dead still.
    var cardsDrift: Bool {
        didSet { save(Key.cardsDrift, String(cardsDrift)) }
    }

    /// A pile whose top card starts needing you gives one small nudge.
    var wigglesForAttention: Bool {
        didSet { save(Key.wigglesForAttention, String(wigglesForAttention)) }
    }

    /// Nil for the provider's own default.
    var defaultEffort: String? {
        didSet { save(Key.defaultEffort, defaultEffort) }
    }

    var onboardingCompleted: Bool {
        didSet { save(Key.onboardingCompleted, String(onboardingCompleted)) }
    }

    /// How the desktop sets out its piles. Each arrangement keeps its own saved places, so switching
    /// back finds them where they were.
    var desktopArrangement: PileArrangement {
        didSet { save(Key.desktopArrangement, desktopArrangement.rawValue) }
    }

    /// One of the pictures that ship with the app (`Background`), drawn behind the desktop; nil for
    /// your own wallpaper.
    var background: String? {
        didSet { save(Key.background, background) }
    }

    init(store: Store, git: GitService) {
        self.store = store
        self.git = git
        func value(_ key: String) -> String? { (try? store.setting(key)) ?? nil }
        let provider = value(Key.defaultProvider).flatMap(Provider.init) ?? .claudeCode
        defaultProvider = provider
        defaultModel = value(Key.defaultModel).flatMap { Self.offers($0, for: provider) ? $0 : nil }
            ?? ComposerDraft.models(for: provider)[0].id
        defaultPermissionMode = value(Key.defaultPermissionMode).flatMap(PermissionMode.init) ?? .default
        defaultNewWorktree = value(Key.defaultNewWorktree) != "false"
        cleanupThreshold = value(CleanupSettingKey.threshold).flatMap(CleanupThreshold.init) ?? .default
        worktreeRoot = value(Key.worktreeRoot).map { URL(filePath: $0, directoryHint: .isDirectory) }
        newProjectsFolder = value(Key.newProjectsFolder).map { URL(filePath: $0, directoryHint: .isDirectory) }
        editor = value(Key.editor).flatMap(Editor.init)
        notifiesWhenBlocked = value(Key.notifiesWhenBlocked) != "false"
        notifiesWhenFailed = value(Key.notifiesWhenFailed) != "false"
        cardsDrift = value(Key.cardsDrift) != "false"
        wigglesForAttention = value(Key.wigglesForAttention) != "false"
        defaultEffort = value(Key.defaultEffort)
        onboardingCompleted = value(Key.onboardingCompleted) == "true"
        desktopArrangement = value(Key.desktopArrangement).flatMap(PileArrangement.init) ?? .expose
        background = value(Key.background).flatMap { Background.named($0)?.id }
    }

    var effectiveWorktreeRoot: URL {
        worktreeRoot ?? GitService.defaultWorktreesRoot
    }

    /// The remembered editor if it is still installed, otherwise the first installed one.
    var preferredEditor: Editor {
        editor.flatMap { Editor.installed.contains($0) ? $0 : nil } ?? Editor.installed.first ?? .finder
    }

    /// Read before the model exists, so the git service starts with the right root.
    nonisolated static func worktreeRoot(in store: Store) -> URL {
        ((try? store.setting(Key.worktreeRoot)) ?? nil).map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? GitService.defaultWorktreesRoot
    }

    /// The efforts offered for a default, before a session's own model list is known.
    static func efforts(for provider: Provider) -> [String] {
        switch provider {
        case .claudeCode: ["low", "medium", "high", "xhigh"]
        case .codex: ["low", "medium", "high"]
        }
    }

    static func title(ofEffort effort: String) -> String {
        effort == "xhigh" ? "X-high" : effort.capitalized
    }

    private static func offers(_ model: String, for provider: Provider) -> Bool {
        ComposerDraft.models(for: provider).contains { $0.id == model }
    }

    /// A small write, done in place so quick changes to one setting land in order.
    private func save(_ key: String, _ value: String?) {
        do { try store.setSetting(key, to: value) } catch { Log.app.error("Saving \(key, privacy: .public) failed: \(error, privacy: .public)") }
    }
}
