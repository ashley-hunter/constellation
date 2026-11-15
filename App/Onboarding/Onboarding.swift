import AppKit
import ConstellationCore
import ConstellationGit
import ConstellationProviders
import Observation
@preconcurrency import UserNotifications

enum OnboardingStep: Int, CaseIterable, Comparable {
    case welcome, agents, projects, background, defaults, keyboard, permissions, done

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var next: Self? { Self(rawValue: rawValue + 1) }
    var previous: Self? { Self(rawValue: rawValue - 1) }

    init?(name: String) {
        guard let step = Self.allCases.first(where: { "\($0)" == name }) else { return nil }
        self = step
    }
}

/// A repository onboarding offers as a project.
struct ProjectChoice: Identifiable, Hashable {
    var url: URL
    var modified: Date?
    var isChosen: Bool
    /// Already a project, from an earlier run.
    var isExisting = false

    var id: URL { url }
    var name: String { url.lastPathComponent }
}

/// The rows that end the projects step's list.
enum ProjectAction: CaseIterable {
    case addFolder, clone
}

/// The Clone from a URL… row: a button, its URL field with what went wrong last, or the clone running.
enum CloneField: Equatable {
    case closed
    case entering(url: String, error: String?)
    case cloning(url: String)

    var isOpen: Bool { self != .closed }
}

/// A fix running in onboarding's terminal: an install or a sign-in.
struct ProviderFix: Equatable {
    enum Kind { case install, signIn }
    let provider: Provider
    let kind: Kind
    let id = UUID()

    var command: String {
        kind == .install ? ProviderCheck.installCommand(for: provider) : ProviderCheck.signInCommand(for: provider)
    }

    var title: String {
        "\(kind == .install ? "Installing" : "Signing in to") \(provider.displayName)"
    }
}

/// What the desktop shows once onboarding hands over: the launcher, or each project's first pile by
/// project folder, in desktop points.
enum OnboardingLanding: Equatable {
    struct Place: Equatable {
        /// Top centre of the pile's label.
        var header: CGPoint
        /// Its top card, or where a new project's first session will go.
        var cards: CGRect
    }

    case launcher
    case projects([URL: Place])
}

/// Done handing over to the desktop: the miniature grows to fill the screen and lands where the
/// desktop will be, or with Reduce Motion only fades.
enum OnboardingFinish: Equatable {
    case zooming(into: OnboardingLanding)
    case fading
}

/// The keyboard step's things to try.
enum KeyLesson: CaseIterable, Hashable {
    case move, cycle, attention, digits, summon
}

/// The first-run flow's state. Choices for new sessions are written to Settings as you make them;
/// projects are added when the flow finishes.
@Observable
@MainActor
final class Onboarding {
    private(set) var step: OnboardingStep
    /// +1 going forward, -1 going back, for the direction steps slide.
    private(set) var direction = 1
    /// Set as Done starts handing over to the desktop, and never cleared.
    private(set) var finishing: OnboardingFinish?
    /// The Done step's miniature is growing or fading into the real desktop.
    var isExpanding: Bool { finishing != nil }
    /// Done grows the miniature to fill the screen.
    var zoomsIntoDesktop: Bool {
        if case .zooming? = finishing { true } else { false }
    }
    /// The keyboard cursor within the current step's choices.
    var selection = 0
    /// The selection ring shows once the arrows have been used on this step.
    var showsSelection = false

    func isSelected(_ index: Int) -> Bool { showsSelection && selection == index }

    private(set) var statuses: [Provider: ProviderStatus] = [:]
    private(set) var checking: Set<Provider> = []
    var fix: ProviderFix?

    private(set) var projects: [ProjectChoice] = []
    private(set) var isScanning = true
    private(set) var clone: CloneField = .closed
    /// The open field's text, for it to edit.
    var cloneURL: String {
        get {
            switch clone {
            case .entering(let url, _), .cloning(let url): url
            case .closed: ""
            }
        }
        set {
            if case .entering(_, let error) = clone { clone = .entering(url: newValue, error: error) }
        }
    }

    var lessonsDone: Set<KeyLesson> = []
    /// The pile focused on the keyboard step's miniature, left to right.
    var tutorialFocus = 0
    /// How far Tab has turned each of the keyboard step's piles.
    var tutorialTurns = Array(repeating: 0, count: Onboarding.tutorialPiles.count)
    var showsDigitHints = false
    private(set) var summonCount = 0

    private(set) var notificationStatus: UNAuthorizationStatus?
    /// Project folders child processes can't read. Nil until checked.
    private(set) var blockedFolders: [URL]?

    @ObservationIgnored unowned let model: AppModel

    init(model: AppModel, step: OnboardingStep = .welcome) {
        self.model = model
        self.step = step
        projects = model.projects.map { ProjectChoice(url: $0.rootPath, isChosen: true, isExisting: true) }
        checkProviders()
        scanProjects()
        Task {
            await refreshNotificationStatus()
            await checkPrivacy()
        }
    }

    var settings: AppSettings { model.settings }

    var hasUsableProvider: Bool { statuses.values.contains(where: \.isUsable) }

    var canContinue: Bool {
        switch step {
        case .agents: hasUsableProvider
        default: true
        }
    }

    var chosenProjects: [ProjectChoice] { projects.filter(\.isChosen) }

    /// Continue on the projects step says it will go on with none, so a blank desktop isn't a surprise.
    var continuesWithoutProjects: Bool { step == .projects && !isScanning && chosenProjects.isEmpty }

    // MARK: Moving

    func advance() {
        guard canContinue, !isExpanding else { return }
        guard let next = step.next else { return finish(startingSession: false) }
        if step == .agents { adoptUsableProvider() }
        go(to: next, direction: 1)
    }

    func back() {
        guard let previous = step.previous, !isExpanding else { return }
        go(to: previous, direction: -1)
    }

    /// Skip for now: on Welcome, straight to the desktop when an agent is ready and there's a
    /// project to land on (otherwise to Agents or Projects); elsewhere, past this step.
    func skip() {
        switch step {
        case .welcome:
            if !hasUsableProvider {
                go(to: .agents, direction: 1)
            } else if chosenProjects.isEmpty {
                go(to: .projects, direction: 1)
            } else {
                finish(startingSession: false)
            }
        case .projects:
            for index in projects.indices where !projects[index].isExisting { projects[index].isChosen = false }
            advance()
        default:
            advance()
        }
    }

    private func go(to step: OnboardingStep, direction: Int) {
        self.direction = direction
        selection = 0
        showsSelection = false
        fix = nil
        clone = .closed
        showsDigitHints = false
        self.step = step
        switch step {
        case .agents: checkProviders()
        case .background: selection = Background.all.firstIndex { $0.id == settings.background }.map { $0 + 1 } ?? 0
        case .permissions:
            Task {
                await refreshNotificationStatus()
                await checkPrivacy()
            }
        default: break
        }
    }

    /// Adds the chosen projects, grows the miniature into the desktop, then hands over to it.
    func finish(startingSession: Bool) {
        guard !isExpanding else { return }
        adoptUsableProvider()
        let toAdd = chosenProjects.filter { !$0.isExisting }.map(\.url)
        finishing = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? .fading
            : .zooming(into: model.onboardingLanding(adding: toAdd, startingSession: startingSession))
        let sessionFolder = startingSession ? chosenProjects.first?.url : nil
        let model = model
        Task {
            async let pause: Void? = try? Task.sleep(for: .milliseconds(620))
            await model.addProjects(toAdd)
            _ = await pause
            model.completeOnboarding(startingSessionIn: sessionFolder)
        }
    }

    // MARK: Agents

    func checkProviders() {
        for provider in Provider.allCases { check(provider) }
    }

    func check(_ provider: Provider) {
        guard !checking.contains(provider) else { return }
        checking.insert(provider)
        Task {
            await BinaryLocator.shared.invalidate()
            let status = await ProviderCheck.check(provider)
            statuses[provider] = status
            checking.remove(provider)
            if step == .agents, fix?.provider == provider, status.isUsable, fix?.kind == .signIn || status.state == .ready {
                fix = nil
            }
        }
    }

    func runFix(for provider: Provider) {
        guard let status = statuses[provider] else { return }
        switch status.state {
        case .missing: fix = ProviderFix(provider: provider, kind: .install)
        case .signedOut, .unknown: fix = ProviderFix(provider: provider, kind: .signIn)
        case .ready: check(provider)
        }
    }

    /// The default provider must be one that can run; prefer the one already set.
    private func adoptUsableProvider() {
        if statuses[settings.defaultProvider]?.isUsable == true { return }
        if let usable = Provider.allCases.first(where: { statuses[$0]?.isUsable == true }) {
            settings.defaultProvider = usable
        }
    }

    // MARK: Projects

    private func scanProjects() {
        Task {
            let found = await Task.detached { RepositoryScan.suggestions() }.value
            let known = Set(projects.map { $0.url.standardizedFileURL.path(percentEncoded: false) })
            let suggestions = found
                .filter { !known.contains($0.url.standardizedFileURL.path(percentEncoded: false)) }
                .map { ProjectChoice(url: $0.url, modified: $0.modified, isChosen: $0.isRecent()) }
            projects += suggestions
            isScanning = false
        }
    }

    func toggle(_ choice: ProjectChoice) {
        guard let index = projects.firstIndex(where: { $0.id == choice.id }), !projects[index].isExisting else { return }
        projects[index].isChosen.toggle()
    }

    /// A dropped or picked folder joins the list, chosen. A folder inside a repo adds the repo.
    func addFolders(_ urls: [URL]) {
        let git = model.services.git
        Task {
            for url in urls {
                guard let repository = try? await git.inspectProject(at: url) else {
                    model.notice = "\(url.lastPathComponent) isn't a git repository."
                    continue
                }
                choose(root: repository.root)
            }
        }
    }

    private func choose(root: URL) {
        let root = root.standardizedFileURL
        if let index = projects.firstIndex(where: { $0.url.standardizedFileURL == root }) {
            if !projects[index].isExisting { projects[index].isChosen = true }
        } else {
            let index = projects.firstIndex { !$0.isExisting } ?? projects.endIndex
            projects.insert(ProjectChoice(url: root, modified: .now, isChosen: true), at: index)
            // Keep the cursor on the row it was on, an action row most likely.
            if step == .projects, selection >= index { selection += 1 }
        }
    }

    /// Clones into ~/code/<name> and adds the clone, chosen. An existing folder is left alone.
    func startClone() {
        guard case .entering(let typed, _) = clone else { return }
        let remote = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remote.isEmpty else { return }
        guard let name = GitService.repositoryName(fromCloneURL: remote) else {
            clone = .entering(url: typed, error: "That doesn't look like a repository URL.")
            return
        }
        let folder = URL.homeDirectory.appending(path: "code/\(name)", directoryHint: .isDirectory)
        guard !FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) else {
            clone = .entering(url: typed, error: "~/code/\(name) already exists. Use Add a folder… to add it.")
            return
        }
        clone = .cloning(url: typed)
        let git = model.services.git
        Task {
            // Leaving the step closes the field; a clone that finishes after is still chosen.
            let isShown = { self.clone == .cloning(url: typed) }
            do {
                let repository = try await git.clone(remote, into: folder)
                choose(root: repository.root)
                if isShown() { clone = .closed }
            } catch {
                if isShown() { clone = .entering(url: typed, error: "Couldn't clone it. \(error.gitActionMessage)") }
            }
        }
    }

    /// Esc in the field closes it, but not while it clones, as the clone can't be called off.
    func closeCloneField() {
        if case .entering = clone { clone = .closed }
    }

    /// The rows after the projects: Add a folder… then Clone from a URL….
    func act(on action: ProjectAction) {
        switch action {
        case .addFolder: presentFolderPanel()
        case .clone: if clone == .closed { clone = .entering(url: "", error: nil) }
        }
    }

    /// The action row the cursor sits on, if any. With no projects, Add a folder… holds it.
    var selectedProjectAction: ProjectAction? {
        guard step == .projects, !isScanning, showsSelection || projects.isEmpty else { return nil }
        let index = selection - projects.count
        return ProjectAction.allCases.indices.contains(index) ? ProjectAction.allCases[index] : nil
    }

    func presentFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose git repositories to work in."
        guard panel.runModal() == .OK else { return }
        addFolders(panel.urls)
    }

    // MARK: Keyboard

    func complete(_ lesson: KeyLesson) {
        lessonsDone.insert(lesson)
    }

    func noteSummon() {
        summonCount += 1
        complete(.summon)
    }

    // MARK: Permissions

    func refreshNotificationStatus() async {
        notificationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func requestNotifications() {
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            await refreshNotificationStatus()
        }
    }

    func checkPrivacy() async {
        let folders = chosenProjects.map(\.url)
        blockedFolders = await PrivacyCheck.blockedFolders(folders)
    }

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")!)
    }

    func openNotificationSettings() {
        let id = Bundle.main.bundleIdentifier ?? "dev.ashleyhunter.constellation"
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")!)
    }
}
