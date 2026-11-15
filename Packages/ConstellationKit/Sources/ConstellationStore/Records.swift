import ConstellationCore
import Foundation
import GRDB

/// Shared encoding for every table: UUIDs as text, dates as exact doubles, nested values as JSON.
protocol StoreRecord: Codable, FetchableRecord, PersistableRecord {}

extension StoreRecord {
    static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy { .uppercaseString }
    static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .timeIntervalSinceReferenceDate
    }
    static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .timeIntervalSinceReferenceDate
    }
    static func databaseJSONEncoder(for column: String) -> JSONEncoder { StoreJSON.encoder() }
    static func databaseJSONDecoder(for column: String) -> JSONDecoder { JSONDecoder() }
}

enum StoreJSON {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }
}

struct ProjectRecord: StoreRecord {
    static let databaseTableName = "projects"

    var id: UUID
    var name: String
    var rootPath: URL
    var swatch: ProjectSwatch
    var setupScriptPath: URL?
    var defaultProvider: Provider
    var defaultBranch: String

    init(_ project: Project) {
        id = project.id
        name = project.name
        rootPath = project.rootPath
        swatch = project.swatch
        setupScriptPath = project.setupScriptPath
        defaultProvider = project.defaultProvider
        defaultBranch = project.defaultBranch
    }

    var project: Project {
        Project(
            id: id,
            name: name,
            rootPath: rootPath,
            swatch: swatch,
            setupScriptPath: setupScriptPath,
            defaultProvider: defaultProvider,
            defaultBranch: defaultBranch
        )
    }
}

struct SessionRecord: StoreRecord {
    static let databaseTableName = "sessions"

    var id: UUID
    var projectId: UUID
    var host: ConstellationCore.Host
    var provider: Provider
    var model: String
    var permissionMode: PermissionMode
    var title: String
    var worktreePath: URL
    var usesWorktree: Bool
    var branch: String
    var baseBranch: String
    var nativeID: String?
    var createdAt: Date
    var lastActivityAt: Date
    var lastSeenAt: Date?
    var runState: RunState
    var failureMessage: String?
    var lifecycle: Lifecycle
    var outcome: Outcome?
    var pullRequest: PullRequestInfo?
    var filesTouched: [String]

    init(_ session: Session) {
        id = session.id
        projectId = session.projectID
        host = session.host
        provider = session.provider
        model = session.model
        permissionMode = session.permissionMode
        title = session.title
        worktreePath = session.worktreePath
        usesWorktree = session.usesWorktree
        branch = session.branch
        baseBranch = session.baseBranch
        nativeID = session.nativeID
        createdAt = session.createdAt
        lastActivityAt = session.lastActivityAt
        lastSeenAt = session.lastSeenAt
        runState = session.runState
        failureMessage = session.failureMessage
        lifecycle = session.lifecycle
        outcome = session.outcome
        pullRequest = session.pullRequest
        filesTouched = session.filesTouched.sorted()
    }

    func session(asks: [Ask]) -> Session {
        var session = Session(
            id: id,
            projectID: projectId,
            host: host,
            provider: provider,
            model: model,
            permissionMode: permissionMode,
            title: title,
            worktreePath: worktreePath,
            usesWorktree: usesWorktree,
            branch: branch,
            baseBranch: baseBranch,
            nativeID: nativeID,
            createdAt: createdAt,
            runState: runState,
            lifecycle: lifecycle
        )
        session.lastActivityAt = lastActivityAt
        session.lastSeenAt = lastSeenAt
        session.failureMessage = failureMessage
        session.asks = asks
        session.outcome = outcome
        session.pullRequest = pullRequest
        session.filesTouched = Set(filesTouched)
        return session
    }
}

struct TurnSettingsRecord: StoreRecord {
    static let databaseTableName = "session_turn_settings"

    var sessionId: UUID
    var effort: String?
    var fastMode: Bool

    init(_ session: Session) {
        sessionId = session.id
        effort = session.effort
        fastMode = session.fastMode
    }

    func apply(to session: inout Session) {
        session.effort = effort
        session.fastMode = fastMode
    }
}

struct AskRecord: StoreRecord {
    static let databaseTableName = "asks"

    var id: String
    var sessionId: UUID
    var position: Int
    var kind: AskKind
    var createdAt: Date
    var status: AskStatus

    init(_ ask: Ask, position: Int) {
        id = ask.id
        sessionId = ask.sessionID
        self.position = position
        kind = ask.kind
        createdAt = ask.createdAt
        status = ask.status
    }

    var ask: Ask {
        Ask(id: id, sessionID: sessionId, kind: kind, createdAt: createdAt, status: status)
    }
}

struct EventRecord: StoreRecord {
    static let databaseTableName = "events"

    var id: Int64?
    var sessionId: UUID
    var sequence: Int
    var time: Date
    var kind: String
    var payload: SessionEvent

    init(_ stored: StoredEvent) {
        sessionId = stored.sessionID
        sequence = stored.sequence
        time = stored.time
        kind = stored.event.kindName
        payload = stored.event
    }

    var stored: StoredEvent {
        StoredEvent(sessionID: sessionId, sequence: sequence, time: time, event: payload)
    }
}

struct TerminalRecord: StoreRecord {
    static let databaseTableName = "terminals"

    var id: UUID
    var projectId: UUID
    var workingDirectory: URL
    var sessionId: UUID?
    var title: String
    var state: Terminal.State
    var lastExitCode: Int32?
    var createdAt: Date
    var url: URL?
    var command: String?
    var note: String?

    init(_ terminal: Terminal) {
        id = terminal.id
        projectId = terminal.projectID
        workingDirectory = terminal.workingDirectory
        sessionId = terminal.sessionID
        title = terminal.title
        state = terminal.state
        lastExitCode = terminal.lastExitCode
        createdAt = terminal.createdAt
        url = terminal.url
        command = terminal.command
        note = terminal.note
    }

    var terminal: Terminal {
        Terminal(
            id: id,
            projectID: projectId,
            workingDirectory: workingDirectory,
            sessionID: sessionId,
            title: title,
            state: state,
            lastExitCode: lastExitCode,
            createdAt: createdAt,
            url: url,
            command: command,
            note: note
        )
    }
}

struct LayoutRecord: StoreRecord {
    static let databaseTableName = "layouts"

    var arrangement: Arrangement
    var itemKind: String
    var itemId: UUID
    var x: Double
    var y: Double

    init(arrangement: Arrangement, item: TileItem, position: TilePosition) {
        self.arrangement = arrangement
        (itemKind, itemId) = item.columns
        x = position.x
        y = position.y
    }

    var item: TileItem? { TileItem(kind: itemKind, id: itemId) }
    var position: TilePosition { TilePosition(x: x, y: y) }
}

struct GroupRecord: StoreRecord {
    static let databaseTableName = "groups"

    var id: UUID
    var origin: RelatedGroup.Origin
}

struct GroupMemberRecord: StoreRecord {
    static let databaseTableName = "group_members"

    var groupId: UUID
    var itemKind: String
    var itemId: UUID

    init(groupID: UUID, item: TileItem) {
        groupId = groupID
        (itemKind, itemId) = item.columns
    }

    var item: TileItem? { TileItem(kind: itemKind, id: itemId) }
}

struct QueuedMessageRecord: StoreRecord {
    static let databaseTableName = "queued_messages"

    var id: UUID
    var sessionId: UUID
    var position: Int
    var message: UserMessage
    var createdAt: Date

    init(_ queued: QueuedMessage, position: Int) {
        id = queued.id
        sessionId = queued.sessionID
        self.position = position
        message = queued.message
        createdAt = queued.createdAt
    }

    var queued: QueuedMessage {
        QueuedMessage(id: id, sessionID: sessionId, message: message, createdAt: createdAt)
    }
}

struct SettingRecord: StoreRecord {
    static let databaseTableName = "settings"

    var key: String
    var value: String
}

extension TileItem {
    var columns: (kind: String, id: UUID) {
        switch self {
        case .session(let id): ("session", id)
        case .terminal(let id): ("terminal", id)
        }
    }

    init?(kind: String, id: UUID) {
        switch kind {
        case "session": self = .session(id)
        case "terminal": self = .terminal(id)
        default: return nil
        }
    }
}

extension SessionEvent {
    /// The case name, stored beside the payload so the log can be filtered without decoding it.
    var kindName: String {
        switch self {
        case .started: "started"
        case .userMessage: "userMessage"
        case .checkpoint: "checkpoint"
        case .conversationHead: "conversationHead"
        case .rewound: "rewound"
        case .assistantText: "assistantText"
        case .toolCall: "toolCall"
        case .toolResult: "toolResult"
        case .runState: "runState"
        case .failed: "failed"
        case .interrupted: "interrupted"
        case .note: "note"
        case .askRaised: "askRaised"
        case .askWithdrawn: "askWithdrawn"
        case .outcome: "outcome"
        case .usage: "usage"
        case .exited: "exited"
        }
    }

    /// The text full-text search covers: user and assistant messages and tool summaries.
    var searchableText: String? {
        let text: String
        switch self {
        case .userMessage(let message, let attachments): text = ([message] + (attachments ?? []).map(\.name)).joined(separator: " ")
        case .assistantText(let message, _): text = message
        case .toolCall(let call): text = call.summary
        case .toolResult(let result): text = result.summary
        default: return nil
        }
        return text.isEmpty ? nil : text
    }
}
