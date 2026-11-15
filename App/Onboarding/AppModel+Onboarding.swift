import ConstellationCore
import Foundation

/// Starting and finishing the first-run flow.
extension AppModel {
    /// Shown at launch while there are no projects, finished or not: the desktop has nothing to offer then.
    /// `-ConstellationOnboardingStep <step>` opens it at a step, for development.
    func beginOnboardingIfNeeded() {
        if let name = UserDefaults.standard.string(forKey: "ConstellationOnboardingStep") {
            beginOnboarding(at: OnboardingStep(name: name) ?? .welcome)
        } else if projects.isEmpty {
            beginOnboarding()
        }
    }

    func beginOnboarding(at step: OnboardingStep = .welcome) {
        clearFront()
        leaveOpenDraft()
        openedSessionID = nil
        onboarding = Onboarding(model: self, step: step)
    }

    /// Hands over to the desktop, opening a new session in `folder`'s project when one is given.
    func completeOnboarding(startingSessionIn folder: URL?) {
        settings.onboardingCompleted = true
        onboarding = nil
        guard let folder else { return }
        let project = projects.first { $0.rootPath.standardizedFileURL == folder.standardizedFileURL } ?? projects.first
        perform(.sessionNew, argument: project?.id.uuidString)
    }

    /// Where Done's zoom should land once `folders` are added: the launcher when the desktop will be
    /// empty, otherwise each project's first pile, top card and label, laid out as the desktop will
    /// lay it out. A new project stands in as a pile of one where its first session will go.
    func onboardingLanding(adding folders: [URL], startingSession: Bool) -> OnboardingLanding {
        let hasTiles = !terminalsByID.isEmpty || sessionsByID.values.contains { [.full, .titleBar].contains(LifecycleRules.presentation(of: $0)) }
        guard startingSession || hasTiles else { return .launcher }
        let piles = desktopPiles
        let added = folders.map { folder in
            Pile(id: .worktree(folder.standardizedFileURL.path(percentEncoded: false)), projectID: UUID(), cards: [.session(UUID())])
        }
        let landed = pilesLayout(piles + added)
        func place(of pile: Pile.ID?) -> OnboardingLanding.Place? {
            guard let top = landed.cards.first(where: { $0.pile == pile && $0.depth == 0 }),
                  let label = landed.labels.first(where: { $0.pile == pile }) else { return nil }
            return OnboardingLanding.Place(header: CGPoint(x: label.frame.midX, y: label.frame.minY), cards: top.frame)
        }
        var places: [URL: OnboardingLanding.Place] = [:]
        for project in projects {
            places[project.rootPath.standardizedFileURL] = place(of: piles.first { $0.projectID == project.id }?.id)
        }
        for (folder, pile) in zip(folders, added) {
            places[folder.standardizedFileURL] = place(of: pile.id)
        }
        return .projects(places)
    }

    /// Adds each folder's repository as a project, in order, skipping ones already added.
    func addProjects(_ folders: [URL]) async {
        for folder in folders {
            guard let repository = try? await services.git.inspectProject(at: folder) else { continue }
            let root = repository.root.standardizedFileURL
            if projects.contains(where: { $0.rootPath.standardizedFileURL == root }) { continue }
            register(repository)
        }
    }
}

extension ActionID {
    static let onboarding: ActionID = "app.onboarding"
}

extension ActionRegistry {
    static var onboardingActions: [PaletteAction] {
        [
            PaletteAction(
                id: .onboarding, title: "Run onboarding", keywords: ["welcome", "setup", "first run", "tour", "agents", "sign in"],
                systemImage: "sparkles", section: .command,
                isAvailable: { context, _ in context.model.onboarding == nil },
                perform: { context, _ in context.model.beginOnboarding() }
            ),
        ]
    }
}
