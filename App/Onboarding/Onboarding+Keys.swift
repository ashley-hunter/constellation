import ConstellationCore
import Foundation

/// Onboarding is keyboard-first: ↵ continues, esc goes back, arrows move between a step's choices
/// and space picks one. The keyboard step listens for the keys it teaches.
extension Onboarding {
    /// The ⌘ chords that still reach the menu bar while onboarding shows.
    private static let menuChords: Set<String> = ["q", "h", "m", ","]

    func handle(_ stroke: KeyStroke, inShell: Bool) -> Bool {
        if inShell { return false }
        // The clone URL field types every key but esc, which closes it.
        if step == .projects, clone.isOpen {
            guard stroke == KeyStroke(key: "escape") else { return false }
            closeCloneField()
            return true
        }
        if stroke.modifiers.contains(.command), stroke.key.count == 1, !stroke.key.first!.isNumber {
            if stroke.key == "o", step == .projects {
                presentFolderPanel()
                return true
            }
            if step == .keyboard, handleLesson(stroke) { return true }
            return !Self.menuChords.contains(stroke.key)
        }
        if step == .keyboard, handleLesson(stroke) { return true }
        switch (stroke.key, stroke.modifiers) {
        case ("return", []):
            if let action = selectedProjectAction {
                act(on: action)
                return true
            }
            if step == .done { finish(startingSession: canStartSession) } else { advance() }
            revealSelection()
        case ("escape", []):
            if step == .welcome { return true }
            back()
            revealSelection()
        case ("left", []), ("right", []), ("up", []), ("down", []):
            moveSelection(stroke.key)
        case ("space", []):
            choose()
        default:
            return stroke.modifiers.contains(.command)
        }
        return true
    }

    var canStartSession: Bool { !chosenProjects.isEmpty && hasUsableProvider }

    /// How many choices the arrows move between on this step.
    private var choiceCount: Int {
        switch step {
        case .agents: Provider.allCases.count
        case .projects: projects.count + ProjectAction.allCases.count
        case .background: Background.all.count + 1
        case .defaults: DefaultsRow.allCases.count
        case .permissions: permissionCards.count
        default: 0
        }
    }

    private func moveSelection(_ key: String) {
        guard choiceCount > 0 else { return }
        // An empty projects step already shows its cursor on Add a folder….
        guard showsSelection || selectedProjectAction != nil else {
            showsSelection = true
            return
        }
        showsSelection = true
        switch step {
        case .defaults:
            switch key {
            case "up": selection = max(0, selection - 1)
            case "down": selection = min(choiceCount - 1, selection + 1)
            default: cycleDefault(DefaultsRow.allCases[selection], by: key == "left" ? -1 : 1)
            }
        case .background:
            let delta = switch key {
            case "left": -1
            case "right": 1
            case "up": -3
            default: 3
            }
            chooseBackground(at: min(choiceCount - 1, max(0, selection + delta)))
        case .projects:
            // Projects sit two to a row; the action rows below them are one wide.
            let count = projects.count
            let delta = switch key {
            case "left": -1
            case "right": 1
            case "up": selection >= count ? -1 : -2
            default: selection >= count ? 1 : 2
            }
            var next = selection + delta
            if selection < count, next > count { next = count }
            selection = min(choiceCount - 1, max(0, next))
        default:
            let delta = key == "left" || key == "up" ? -1 : 1
            selection = min(choiceCount - 1, max(0, selection + delta))
        }
    }

    /// A step reached by keyboard shows its cursor straight away, so the first arrow press acts.
    private func revealSelection() {
        if choiceCount > 0 { showsSelection = true }
    }

    private func choose() {
        // Space acts only on a choice the cursor visibly sits on.
        guard showsSelection || choiceCount == 0 || selectedProjectAction != nil else {
            showsSelection = true
            return
        }
        switch step {
        case .agents:
            runFix(for: Provider.allCases[min(selection, Provider.allCases.count - 1)])
        case .projects:
            if projects.indices.contains(selection) {
                toggle(projects[selection])
            } else if let action = selectedProjectAction {
                act(on: action)
            }
        case .defaults:
            cycleDefault(DefaultsRow.allCases[selection], by: 1)
        case .permissions:
            if permissionCards.indices.contains(selection) { act(on: permissionCards[selection]) }
        default:
            break
        }
    }

    // MARK: Background

    /// Your wallpaper at 0, then the app's own pictures, shown behind everything at once.
    func chooseBackground(at index: Int) {
        selection = index
        settings.background = index == 0 ? nil : Background.all[index - 1].id
    }

    // MARK: Defaults

    enum DefaultsRow: CaseIterable {
        case provider, model, effort, permissions, worktree
    }

    var usableProviders: [Provider] {
        Provider.allCases.filter { statuses[$0]?.isUsable ?? false }
    }

    func cycleDefault(_ row: DefaultsRow, by delta: Int) {
        func cycled<T: Equatable>(_ values: [T], from current: T) -> T {
            guard !values.isEmpty else { return current }
            let index = values.firstIndex(of: current) ?? 0
            return values[(index + delta + values.count) % values.count]
        }
        switch row {
        case .provider:
            let providers = usableProviders.isEmpty ? Provider.allCases : usableProviders
            settings.defaultProvider = cycled(providers, from: settings.defaultProvider)
        case .model:
            settings.defaultModel = cycled(ComposerDraft.models(for: settings.defaultProvider).map(\.id), from: settings.defaultModel)
        case .effort:
            let efforts: [String?] = [nil] + AppSettings.efforts(for: settings.defaultProvider)
            settings.defaultEffort = cycled(efforts, from: settings.defaultEffort)
        case .permissions:
            settings.defaultPermissionMode = cycled(PermissionMode.allCases, from: settings.defaultPermissionMode)
        case .worktree:
            settings.defaultNewWorktree.toggle()
        }
    }

    // MARK: Permissions

    enum PermissionCard: Hashable {
        case notifications, fullDiskAccess
    }

    var permissionCards: [PermissionCard] {
        blockedFolders?.isEmpty == false ? [.notifications, .fullDiskAccess] : [.notifications]
    }

    func act(on card: PermissionCard) {
        switch card {
        case .notifications:
            if notificationStatus == .notDetermined { requestNotifications() } else { openNotificationSettings() }
        case .fullDiskAccess:
            openFullDiskAccessSettings()
        }
    }

    // MARK: Keyboard lessons

    /// The keyboard step's piles, as ghost ids from the top down. The one that needs you sits on
    /// top of the last pile, as it would rise on the desktop.
    static let tutorialPiles = [[0, 3], [2, 5], [1, 4]]

    /// The ghost on top of a tutorial pile, after Tab has turned it.
    func tutorialTop(of pile: Int) -> Int {
        let cards = Self.tutorialPiles[pile]
        return cards[tutorialTurns[pile] % cards.count]
    }

    private func handleLesson(_ stroke: KeyStroke) -> Bool {
        if stroke.modifiers == .option, stroke.key == "space" {
            noteSummon()
            return true
        }
        if stroke.key == "tab", stroke.modifiers.subtracting(.shift).isEmpty {
            tutorialTurns[tutorialFocus] += stroke.modifiers.contains(.shift) ? Self.tutorialPiles[tutorialFocus].count - 1 : 1
            complete(.cycle)
            return true
        }
        if stroke.key == "tab", stroke.modifiers.subtracting(.shift) == .option {
            tutorialFocus = Self.tutorialPiles.firstIndex { $0.contains(1) } ?? 0
            complete(.attention)
            return true
        }
        if stroke.modifiers.contains(.command), let digit = Int(stroke.key), Self.tutorialPiles.indices.contains(digit - 1) {
            tutorialFocus = digit - 1
            complete(.digits)
            return true
        }
        guard stroke.modifiers.isEmpty, ["left", "right"].contains(stroke.key) else { return false }
        tutorialFocus = min(Self.tutorialPiles.count - 1, max(0, tutorialFocus + (stroke.key == "left" ? -1 : 1)))
        complete(.move)
        return true
    }
}
