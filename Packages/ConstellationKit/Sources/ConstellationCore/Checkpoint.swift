import Foundation

/// Recorded with each message you send, so the conversation can later be rewound to just before
/// it or forked from it.
public struct Checkpoint: Hashable, Codable, Sendable {
    /// The provider's id for the message's turn. Claude Code: the uuid your message is stored
    /// under. Codex: the id of the turn the message started.
    public var turnID: String?
    /// Claude Code: the last message before yours, which a rewind resumes at. Nil at the start of
    /// a conversation, or when the provider didn't know it (filled in from the last turn's head).
    public var resumeAt: String?
    /// The worktree as it was when the message was sent, committed under
    /// `refs/constellation/<session>/<commit>`. Nil when no snapshot was taken.
    public var commit: String?

    public init(turnID: String? = nil, resumeAt: String? = nil, commit: String? = nil) {
        self.turnID = turnID
        self.resumeAt = resumeAt
        self.commit = commit
    }
}

/// Where a provider cuts a conversation when a session resumes after Rewind or Fork.
public enum ConversationCut: Hashable, Sendable {
    /// Keep the conversation up to just before a message. Claude Code: the message to resume at,
    /// nil for a fresh conversation. Codex: the first turn to drop.
    case rewind(before: String?)
    /// Copy the conversation through a message's turn into a new one. Claude Code: the message to
    /// resume at, nil for all of it. Codex: the last turn to keep, nil for all of it.
    case fork(through: String?)
}

/// What the next turn runs with. Changing any of these from the pickers applies from the next
/// message sent.
public struct TurnSettings: Hashable, Codable, Sendable {
    public var model: String
    /// Nil leaves the provider's default.
    public var effort: String?
    /// Codex's priority service tier. Claude Code's fast mode isn't available in print mode.
    public var fastMode: Bool
    public var permissionMode: PermissionMode

    public init(model: String, effort: String? = nil, fastMode: Bool = false, permissionMode: PermissionMode = .default) {
        self.model = model
        self.effort = effort
        self.fastMode = fastMode
        self.permissionMode = permissionMode
    }
}

/// A handle whose model, effort and modes can change between turns.
public protocol TurnSettingsAdjustable: ProviderSessionHandle {
    /// Takes effect from the next message sent.
    func adjust(_ settings: TurnSettings) async
    /// A change the provider refused since the last call, with the settings it still runs with.
    func takeRefusal() async -> SettingsRefusal?
}

/// Settings a running provider would not switch to.
public struct SettingsRefusal: Hashable, Sendable {
    public var applied: TurnSettings
    public var message: String

    public init(applied: TurnSettings, message: String) {
        self.applied = applied
        self.message = message
    }
}

/// One model a picker offers.
public struct ModelChoice: Identifiable, Hashable, Sendable {
    /// What goes to the provider. Empty for Codex's own default.
    public var id: String
    public var title: String
    public var efforts: [String]
    public var defaultEffort: String?
    public var supportsFastMode: Bool

    public init(id: String, title: String, efforts: [String], defaultEffort: String? = nil, supportsFastMode: Bool = false) {
        self.id = id
        self.title = title
        self.efforts = efforts
        self.defaultEffort = defaultEffort
        self.supportsFastMode = supportsFastMode
    }
}

/// An adapter that can say which models it offers.
public protocol ModelCatalog: Sendable {
    func models() async throws -> [ModelChoice]
}

extension Session {
    public var turnSettings: TurnSettings {
        get { TurnSettings(model: model, effort: effort, fastMode: fastMode, permissionMode: permissionMode) }
        set {
            model = newValue.model
            effort = newValue.effort
            fastMode = newValue.fastMode
            permissionMode = newValue.permissionMode
        }
    }
}

extension SessionLaunch {
    public var turnSettings: TurnSettings {
        get { TurnSettings(model: model, effort: effort, fastMode: fastMode, permissionMode: permissionMode) }
        set {
            model = newValue.model
            effort = newValue.effort
            fastMode = newValue.fastMode
            permissionMode = newValue.permissionMode
        }
    }
}
