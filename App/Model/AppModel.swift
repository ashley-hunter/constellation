import AppKit
import ConstellationCore
import ConstellationGitHub
import ConstellationProcess
import Foundation
import Observation

/// Everything the desktop shows, and the intents its views call. Provider events, MCP requests and
/// PR updates all land here on the main actor, so views read one consistent model.
@Observable
@MainActor
final class AppModel {
    let services: AppServices
    let settings: AppSettings

    private(set) var projects: [Project] = []
    var sessionsByID: [UUID: Session] = [:] {
        didSet { if triage != nil { triageSessionsChanged() } }
    }
    var terminalsByID: [UUID: Terminal] = [:]
    private(set) var output: [UUID: LiveOutput] = [:]

    var focusedItem: TileItem? {
        didSet {
            guard focusedItem != oldValue else { return }
            if let oldValue { noteAttention(on: oldValue, isActive: false) }
            if let focusedItem { noteAttention(on: focusedItem, isActive: true) }
            if let inlineComposerID, focusedItem != .session(inlineComposerID) { self.inlineComposerID = nil }
            gatherFans(leavingFor: focusedItem)
            reconsiderSettling()
        }
    }

    var projectFilter: UUID?
    var showFilter: ShowFilter = .all
    var sheet: DesktopSheet?
    /// The empty-state launcher's filter, selection and the draft it is opening.
    let launcher = EmptyLauncher()
    /// What you are typing to each session, kept here so the tile and the session view share it.
    var chatDrafts: [UUID: ChatDraft] = [:]
    /// Drafts whose worktree chip was picked by hand, so it no longer follows the prompt.
    var draftsPlacedByHand: Set<UUID> = []
    /// Messages waiting for each session's turn to end, in send order. Stored.
    var queues: [UUID: [QueuedMessage]] = [:]
    /// The session whose composer has keyboard focus, so ⌘V can paste images and files into it.
    var activeComposerID: UUID?
    /// The focused tile whose inline composer is open.
    var inlineComposerID: UUID?
    /// A session whose showing composer should take keyboard focus, set when you start typing.
    var composerFocusRequest: UUID?
    /// An image shown full size over the desktop.
    var zoomedAttachment: Attachment?
    /// The message shown over the desktop, and what its Undo puts back (see `showNotice`).
    var notices = NoticeSlot<NoticeUndo>()
    /// Sessions closed with ⌘W, off the desktop but not archived until their Undo notice goes.
    var pendingArchives: Set<UUID> = []
    /// Set by the desktop view: the piles fit everything into this size.
    var canvasWidth: Double = 1200
    var canvasHeight: Double = 800
    /// The desktop view has reported its real size, so new piles' slots can be saved.
    @ObservationIgnored var hasMeasuredCanvas = false
    /// Piles: the pile peeking sideways under the pointer.
    var hoveredPile: Pile.ID?
    /// Piles: the pile spread into a row of full cards.
    var fannedPile: Pile.ID? {
        didSet { if fannedPile != oldValue { reconsiderSettling() } }
    }
    /// Piles: a pile still drawn above the rest while it gathers back.
    var raisedPile: Pile.ID?
    /// Piles: a pile dragged by its label, or a card dragged in a spread pile, and how far.
    var pileDrag: PileDrag?
    /// Piles: each pile's slot on the desktop's grid, by pile, saved as `pileSlotsKey`.
    var pileSlots: [Pile.ID: PileSlot] = [:]
    /// Piles: every pile's place in the Exposé order, saved as `pileOrderKey`.
    var pileOrder: [Pile.ID] = []
    /// Piles: the card order you dragged each pile into, saved as `pileOrdersKey`.
    var pileOrders: [Pile.ID: [TileItem]] = [:]
    /// The names you gave worktrees, by folder, saved as `worktreeNamesKey`.
    var worktreeNames: [String: String] = [:]
    /// The Needs you lens: everything that isn't needing you, failed or working dims in place.
    var isLensOn = false
    /// The pile holding ⌘ spread out, whose cards wear letters to jump to.
    var commandSpreadPile: Pile.ID?
    /// A key went with ⌘ while the pile was spread (a chord or a jump), so letting go doesn't wait for a letter.
    var commandSpreadUsed = false
    /// Where ⌥Tab last landed, so it carries on from there when that card stops needing you.
    var attentionCursor: (item: TileItem, index: Int)?
    /// The sidebar is tucked away by default so the desktop gets the whole screen; remembered between launches.
    var isSidebarShown = UserDefaults.standard.bool(forKey: "SidebarShown") {
        didSet { UserDefaults.standard.set(isSidebarShown, forKey: "SidebarShown") }
    }
    /// Piles: the card order piles had when the pointer went into them or they fanned, so nothing
    /// slides out from under you. See `Piles.holding`.
    var heldPiles: [Pile.ID: [TileItem]] = [:]
    /// Piles: the cards the pointer is over, and their piles.
    @ObservationIgnored var pointerCards: [TileItem: Pile.ID] = [:]
    @ObservationIgnored var releaseHoldTask: Task<Void, Never>?
    /// Each session's tokens, cost and context, from its provider's usage reports. Stored.
    var usage: [UUID: SessionUsage] = [:]

    /// Rewind to here, waiting for you to confirm what it loses.
    var rewindRequest: RewindRequest?
    /// The models each provider offers the pickers, loaded on first use.
    var modelCatalogs: [Provider: [ModelChoice]] = [:]

    // Extension points for the answering and session views.
    var openedSessionID: UUID? {
        didSet {
            guard openedSessionID != oldValue else { return }
            reconsiderSettling()
            // Opening anything else, or closing it with esc, stops triage.
            if let triage, openedSessionID != triage.current { self.triage = nil }
            gridFollowsOpened()
        }
    }
    /// The split screen, while it shows. The opened session is always its focused tile; opening
    /// anything else, or closing the opened session, leaves it (see AppModel+Grid).
    var grid: SessionGrid?
    /// The split screen's next slot is showing the sessions to fill it with (see AppModel+Grid).
    var gridPicking: GridPicking?
    /// A session that left the split screen as it was being made, so its view grows back out of
    /// the half it held rather than out of its card.
    var gridReturnID: UUID?
    /// Working through what needs you, one session after another (see AppModel+Triage).
    var triage: TriageRun?
    /// An empty draft closed with esc, thrown away once its panel has finished leaving unless it is
    /// opened again first.
    var discardingDraftID: UUID?
    /// The pane beside the opened session's transcript, when you have asked for one. It opens compact.
    var sessionDetail: SessionDetail? {
        // Only a zoomed tile of the split screen has room for a pane.
        didSet { if sessionDetail != nil, grid?.isZoomed == false { grid?.isZoomed = true } }
    }
    /// The terminal the opened session's Terminal pane shows, when it has several.
    var sessionPaneTerminalID: UUID?
    var openedTerminalID: UUID?
    /// The opened tile whose panel is on screen, from the moment it starts opening until it has
    /// finished closing. Its card stays hidden all that time, as the panel stands in for it.
    var presentingTile: TileItem?
    /// A pile left spread under a panel opened from it, gathered once the panel has gone.
    @ObservationIgnored var gatherAfterClose: Pile.ID?
    /// The kinds of opened panel that fill the desktop, kept until the app quits.
    var maximisedPanels: Set<PanelKind> = []
    /// A new browser's panel opens with its address field focused.
    var browserFocusesAddress = false
    /// What each opened note's editor holds and hasn't saved yet, and the save waiting on a pause.
    @ObservationIgnored var noteEdits: [UUID: String] = [:]
    @ObservationIgnored var noteSaves: [UUID: Task<Void, Never>] = [:]
    /// The first-run flow, while it covers the desktop.
    var onboarding: Onboarding?

    /// The composer's `/` and `@` menus and prompt history.
    @ObservationIgnored let composerAssist = ComposerAssist()
    @ObservationIgnored let terminalHost = TerminalHost()
    @ObservationIgnored let browserHost = BrowserHost()
    /// The dev server each project's shells or agents printed last, by project.
    @ObservationIgnored var localServers: [UUID: URL] = [:]
    /// The address each shell's dev server printed while its command runs: for a task's card to
    /// link to, and a session's Preview to show.
    var shellServers: [UUID: URL] = [:]
    /// The port each worktree's processes are given, chosen once per launch, by path.
    @ObservationIgnored var worktreePorts: [String: Int] = [:]
    /// What each task's run since launch has done; none for one restored from last time and not
    /// run since. Read through `taskPhase(of:)`.
    var taskRuns: [UUID: TaskRun] = [:]
    /// Tasks waiting for their shell's next prompt to type their command.
    @ObservationIgnored var pendingTaskCommands: [UUID: String] = [:]
    /// Each browser's page as last drawn, for its card.
    var browserSnapshots: [UUID: NSImage] = [:]
    /// Each project's icon, found in its repository or from its GitHub organisation (see
    /// `ProjectIcon`); a project without one shows its colour.
    var projectIcons: [UUID: NSImage] = [:]
    /// Projects already looked for, found or not, so each is searched once a launch.
    @ObservationIgnored var projectIconsSought: Set<UUID> = []
    /// Whether the top of each browser snapshot, under its card's title, is light or dark.
    var browserTitleTones: [UUID: WallpaperTone] = [:]
    /// A draft just started from its panel, which morphs into the session view instead of growing from a tile.
    @ObservationIgnored var startedDraftID: UUID?
    /// Sessions started in the project folder because their first message was a question.
    @ObservationIgnored var questionLaunches: Set<UUID> = []
    /// The chat opened before the one opened last, for ⌃⇥ to go back to.
    @ObservationIgnored var lastOpenedSessionID: UUID?
    @ObservationIgnored var previousSessionID: UUID?
    /// keys.conf, the keymap, and the keys being typed.
    @ObservationIgnored let keyboard = KeyboardController()
    /// Each session's provider process. Read through `processPhase(_:)`, start a launch with
    /// `runLaunchTask(_:_:)` and let go of a process with `releaseProcess(_:endingTurnWith:)`.
    @ObservationIgnored var handles: [UUID: any ProviderSessionHandle] = [:]
    @ObservationIgnored var handleTokens: [UUID: UUID] = [:]
    @ObservationIgnored var launchTasks: [UUID: LaunchTask] = [:]
    @ObservationIgnored var lastPrompts: [UUID: UserMessage] = [:]
    /// Worktree snapshots taken just before each message went out, oldest first, waiting for its
    /// checkpoint event. Nil where the snapshot failed.
    @ObservationIgnored var pendingCheckpointCommits: [UUID: [String?]] = [:]
    /// The last message on its way to each session, so the next one goes out after it.
    @ObservationIgnored var deliveries: [UUID: Task<Void, Never>] = [:]
    /// `request_secret` calls waiting on you, keyed by the ask id they raised.
    @ObservationIgnored var mcpSecretRequests: [String: UUID] = [:]
    /// Keys of palette rows run recently, newest first, once read from the store.
    @ObservationIgnored var recentPaletteKeys: [String]?
    @ObservationIgnored var repositories: [UUID: GitHubRepository] = [:]
    @ObservationIgnored private var dwellTasks: [TileItem: Task<Void, Never>] = [:]
    /// The tiles under the pointer, and seen work waiting out its grace before it settles.
    @ObservationIgnored var hoveredItems: Set<TileItem> = []
    @ObservationIgnored var settleTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var pileHoverTask: Task<Void, Never>?
    @ObservationIgnored private var dirtySessions: Set<UUID> = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored var draftSaveTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored let eventLog: AsyncStream<(UUID, SessionEvent, Date)>.Continuation
    @ObservationIgnored private let eventLogStream: AsyncStream<(UUID, SessionEvent, Date)>
    @ObservationIgnored var eventLogTask: Task<Void, Never>?
    /// Holds the write end of the watchdog's pipe for as long as the app runs.
    @ObservationIgnored var watchdog: ChildProcess?

    init(services: AppServices) {
        self.services = services
        settings = AppSettings(store: services.store, git: services.git)
        (eventLogStream, eventLog) = AsyncStream.makeStream()
        notice = services.storeError
        observeBrowsers()
    }

    /// A short message shown over the desktop, e.g. a folder that isn't a git repo. Setting one
    /// replaces the notice showing, letting go of anything its Undo was holding back.
    var notice: String? {
        get { notices.notice?.text }
        set { showNotice(newValue) }
    }

    // MARK: Derived

    var sessions: [Session] {
        sessionsByID.values.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
    }

    var terminals: [Terminal] {
        terminalsByID.values.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
    }

    func project(_ id: UUID?) -> Project? {
        projects.first { $0.id == id }
    }

    func session(for item: TileItem) -> Session? {
        guard case .session(let id) = item else { return nil }
        return sessionsByID[id]
    }

    /// Sessions and terminals that pass the sidebar's project and Show filters.
    var visibleSessions: [Session] {
        sessions.filter { session in
            (projectFilter == nil || session.projectID == projectFilter) && showFilter.matches(session)
                && !isUnplacedDraft(session) && !pendingArchives.contains(session.id)
        }
    }

    /// A draft takes a place on the desktop only once it's kept with something in it: while its panel
    /// is open, or while it's still empty, the layout doesn't shift to make room for it.
    private func isUnplacedDraft(_ session: Session) -> Bool {
        session.isDraft && (openedSessionID == session.id || chatDraft(for: session.id).isEmpty)
    }

    var visibleTerminals: [Terminal] {
        guard showFilter == .all else { return [] }
        return terminals.filter { projectFilter == nil || $0.projectID == projectFilter }
    }

    /// Projects that pass the sidebar's filters: with a Show filter, only those with something showing.
    var shownProjects: [Project] {
        let shown = projects.filter { projectFilter == nil || $0.id == projectFilter }
        return showFilter == .all ? shown : shown.filter { project in visibleSessions.contains { $0.projectID == project.id } }
    }

    /// The desktop as drawn: the focused card at the top of its pile, and whatever is peeked or fanned.
    var geometry: DesktopGeometry {
        pilesGeometry(state: pilesState)
    }

    var blockedCount: Int {
        sessionsByID.values.count { $0.runState == .blocked }
    }

    /// What the clean-up sheet can offer: done, merged or idle, and past the Suggest-after threshold.
    var recededCount: Int {
        guard let interval = cleanupThreshold.interval else { return 0 }
        return recededDoneSessions.count { Date.now.timeIntervalSince($0.lastActivityAt) > interval }
    }

    func count(_ filter: ShowFilter) -> Int {
        sessionsByID.values.count { filter.matches($0) && $0.lifecycle != .archived && !$0.isDraft }
    }

    func output(for sessionID: UUID) -> LiveOutput {
        output[sessionID] ?? LiveOutput()
    }

    // MARK: Desktop intents

    func toggleProjectFilter(_ id: UUID?) {
        projectFilter = projectFilter == id ? nil : id
    }

    func toggleShowFilter(_ filter: ShowFilter) {
        showFilter = showFilter == filter && filter != .all ? .all : filter
    }

    func focus(_ item: TileItem?) {
        focusedItem = item
    }

    func moveFocus(_ direction: FocusDirection) {
        movePileFocus(direction)
    }

    func title(of item: TileItem) -> String {
        switch item {
        case .session(let id): sessionsByID[id]?.title ?? "Session"
        case .terminal(let id): terminalsByID[id].map(displayTitle) ?? "Terminal"
        }
    }

    func dismissSheet() {
        sheet = nil
    }

    // MARK: Lifecycle

    /// Hovering or focusing a tile for `LifecycleRules.seenDwell` marks its session seen.
    func noteAttention(on item: TileItem, isActive: Bool) {
        dwellTasks[item]?.cancel()
        dwellTasks[item] = nil
        guard isActive, case .session(let id) = item, sessionsByID[id]?.lifecycle == .unseen else { return }
        dwellTasks[item] = Task { [weak self] in
            try? await Task.sleep(for: LifecycleRules.seenDwell)
            guard !Task.isCancelled else { return }
            self?.markSeen(id)
        }
    }

    func markSeen(_ id: UUID) {
        updateLifecycle(id, .dwelled)
        reconsiderSettling()
    }

    func updateLifecycle(_ id: UUID, _ event: LifecycleEvent) {
        guard let session = sessionsByID[id] else { return }
        let updated = LifecycleRules.apply(event, to: session)
        guard updated != session else { return }
        sessionsByID[id] = updated
        persist(id)
    }

    // MARK: Persistence

    func persist(_ id: UUID) {
        if sessionsByID[id]?.isDraft == true { return saveDraftSoon(id) }
        dirtySessions.insert(id)
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            self?.saveDirtySessions()
        }
    }

    func saveDirtySessions() {
        saveTask = nil
        let dirty = dirtySessions.compactMap { sessionsByID[$0] }.filter { !$0.isDraft }
        dirtySessions = []
        let store = services.store
        Task.detached {
            for session in dirty {
                do { try store.save(session) } catch { Log.app.error("Saving session failed: \(error, privacy: .public)") }
            }
        }
    }

    func saveSetting(_ key: String, _ value: String?) {
        let store = services.store
        Task.detached { try? store.setSetting(key, to: value) }
    }

    func setOutput(_ output: LiveOutput, for id: UUID) {
        self.output[id] = output
    }

    func appendOutput(_ event: SessionEvent, for id: UUID) {
        self.output[id, default: LiveOutput()].append(event)
    }

    func replaceProjects(_ projects: [Project]) {
        self.projects = projects
    }

    /// Writes queued events in order, so the store batches them every 250 ms.
    func startEventLog() {
        let (stream, recorder) = (eventLogStream, services.recorder)
        eventLogTask = Task.detached {
            for await (id, event, time) in stream {
                await recorder.record(event, for: id, at: time)
            }
        }
    }
}

