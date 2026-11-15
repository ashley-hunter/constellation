import ConstellationCore
import ConstellationProviders
import SwiftUI

/// One of the sample sessions that drift into a constellation on Welcome and then live on the
/// miniature desktop, rearranging as you choose.
struct Ghost: Identifiable {
    enum Kind { case working, blocked, done, terminal }

    let id: Int
    let title: String
    let project: String
    let kind: Kind
    let lines: [String]

    /// For a session: what it's doing or found, a second line, and the footer's status. For a
    /// terminal: the lines of its shell.
    static let all: [Ghost] = [
        Ghost(id: 0, title: "Fix flaky login test", project: "ledger", kind: .working, lines: ["Retrying with a fake clock", "Ran 214 tests, 1 failing", "Working · 3m"]),
        Ghost(id: 1, title: "Add CSV export", project: "ledger", kind: .blocked, lines: ["Can I edit package.json to add papaparse?", "Wrote export/csv.ts", "Needs you"]),
        Ghost(id: 2, title: "Bump Swift to 6.4", project: "atlas", kind: .done, lines: ["Updated 12 packages and all 318 tests pass", "3 files changed", "Done · 4m ago"]),
        Ghost(id: 3, title: "Review PR 214", project: "atlas", kind: .working, lines: ["Checking the migration", "2 comments so far", "Working · 1m"]),
        Ghost(id: 4, title: "Refactor billing sync", project: "orbit", kind: .working, lines: ["Running the suite", "Split SyncJob in two", "Working · 6m"]),
        Ghost(id: 5, title: "zsh", project: "atlas", kind: .terminal, lines: ["$ npm run dev", "ready on :5173", "$"]),
        Ghost(id: 6, title: "Write release notes", project: "orbit", kind: .done, lines: ["Drafted NOTES.md from 18 PRs", "1 file changed", "Done · 12m ago"]),
        Ghost(id: 7, title: "Speed up cold start", project: "atlas", kind: .working, lines: ["Deferring font loading", "It takes 140 ms at launch", "Working · 2m"]),
    ]

    /// The size a ghost is drawn at before it is scaled into place.
    static let designSize = CGSize(width: 240, height: 144)
}

/// Where a ghost sits and how it looks, in screen points.
struct GhostPlacement: Equatable {
    var frame: CGRect
    var opacity = 1.0
    var project: String?
    var swatch: ProjectSwatch?
    var provider: Provider?
    var isDimmed = false
    var isFocused = false
    var badge: String?
    /// The Defaults step's sample tile, which shows the chosen settings.
    var isSample = false
    var tilt = 0.0
    /// Drawing order, so a pile's top card sits over the ones behind it.
    var layer = 0.0
    /// On a pile's top card, how many the pile holds.
    var pileCount: Int?
}

/// A label over an island on the miniature: a project or an agent.
struct SceneLabel: Identifiable, Equatable {
    var id: String
    var text: String
    var origin: CGPoint
    var swatch: ProjectSwatch?
    var status: String?
    var statusColor: Color = Palette.textTertiary
    /// Relative to the miniature's label size; Done's zoom shrinks labels to the real project names.
    var size = 1.0
}

/// Where everything goes for a step: the screen's own geometry on Welcome, the miniature desktop
/// for the steps after it, and the whole screen again as Done grows into the real desktop.
@MainActor
struct OnboardingScene {
    let layout: OnboardingLayout
    let onboarding: Onboarding

    var tiles: [GhostPlacement] = []
    var labels: [SceneLabel] = []
    var showsBanner = false
    var emptyMessage: String?

    init(layout: OnboardingLayout, onboarding: Onboarding, arrived: Bool) {
        self.layout = layout
        self.onboarding = onboarding
        switch onboarding.step {
        case .welcome: placeWelcome(arrived: arrived)
        case .agents: placeAgents()
        case .projects, .background, .done: placeProjects()
        case .defaults: placeSample()
        case .keyboard: placePiles(focus: onboarding.tutorialFocus)
        case .permissions:
            placePiles(focus: nil)
            showsBanner = true
        }
    }

    // MARK: Desktop coordinates

    /// The real desktop's size; the miniature is this scaled down.
    private var desktop: CGSize { layout.size }

    /// The part of the desktop beside the sidebar, where islands go.
    private var region: CGRect {
        // The sidebar starts hidden, as on the desktop, and the piles take its room.
        let left = onboarding.model.isSidebarShown ? 312.0 : 32.0
        return CGRect(x: left, y: 64, width: desktop.width - left - 32, height: desktop.height - 96)
    }

    private var tile: CGSize {
        let width = min(320, (region.width - 64 - 3 * 14) / 4)
        return CGSize(width: width, height: width * 0.6)
    }

    private let gap = 14.0
    /// Room above an island for its label, which is drawn large enough to read in the miniature.
    private let labelSpace = 48.0

    private func screen(_ rect: CGRect) -> CGRect {
        let mini = layout.desktopRect(expanded: onboarding.zoomsIntoDesktop)
        let scale = mini.width / desktop.width
        return CGRect(x: mini.minX + rect.minX * scale, y: mini.minY + rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
    }

    private func screen(_ point: CGPoint) -> CGPoint {
        screen(CGRect(origin: point, size: .zero)).origin
    }

    private var parked: GhostPlacement {
        let centre = CGPoint(x: region.midX, y: region.midY)
        return GhostPlacement(frame: screen(CGRect(x: centre.x - tile.width / 4, y: centre.y - tile.height / 4, width: tile.width / 2, height: tile.height / 2)), opacity: 0)
    }

    // MARK: Steps

    /// Scattered round the title in a loose constellation; before arriving, out past the edges.
    private mutating func placeWelcome(arrived: Bool) {
        let size = layout.size
        let stars: [(x: Double, y: Double, scale: Double, tilt: Double)] = [
            (0.13, 0.21, 1.0, -2), (0.32, 0.11, 0.8, 1.5), (0.73, 0.14, 0.9, 2), (0.89, 0.37, 1.05, -1.5),
            (0.84, 0.75, 0.95, 1), (0.62, 0.89, 0.78, -1), (0.21, 0.80, 1.0, 1.5), (0.08, 0.52, 0.85, -1),
        ]
        let base = min(250, size.width * 0.15)
        tiles = stars.map { star in
            var centre = CGPoint(x: size.width * star.x, y: size.height * star.y)
            if !arrived {
                centre.x = size.width / 2 + (centre.x - size.width / 2) * 2.1
                centre.y = size.height / 2 + (centre.y - size.height / 2) * 2.1
            }
            let width = base * star.scale
            let height = width * 0.6
            return GhostPlacement(
                frame: CGRect(x: centre.x - width / 2, y: centre.y - height / 2, width: width, height: height),
                opacity: arrived ? 0.92 : 0,
                tilt: star.tilt
            )
        }
    }

    /// One island per agent; an agent that isn't ready yet shows its tiles dimmed.
    private mutating func placeAgents() {
        tiles = Array(repeating: parked, count: Ghost.all.count)
        let islandWidth = 2 * tile.width + gap
        let islandHeight = 2 * tile.height + gap + labelSpace
        let spacing = 64.0
        let originX = region.midX - (2 * islandWidth + spacing) / 2
        let originY = region.midY - islandHeight / 2
        for (index, provider) in Provider.allCases.enumerated() {
            let status = onboarding.statuses[provider]
            let x = originX + Double(index) * (islandWidth + spacing)
            let (text, color) = Self.statusLine(status, isChecking: onboarding.checking.contains(provider))
            labels.append(SceneLabel(id: "agent-\(provider.rawValue)", text: provider.displayName, origin: CGPoint(x: x, y: originY), status: text, statusColor: color))
            let slots = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1)]
            for (slot, ghost) in zip(slots, index == 0 ? [0, 1, 2] : [3, 4, 6]) {
                let frame = CGRect(
                    x: x + slot.x * (tile.width + gap), y: originY + labelSpace + slot.y * (tile.height + gap),
                    width: tile.width, height: tile.height
                )
                tiles[ghost] = GhostPlacement(frame: screen(frame), provider: provider, isDimmed: status?.isUsable != true)
            }
        }
    }

    static func statusLine(_ status: ProviderStatus?, isChecking: Bool) -> (String, Color) {
        if isChecking && status == nil { return ("checking", Palette.textTertiary) }
        switch status?.state {
        case .ready?: return ("ready", Palette.done)
        case .unknown?: return ("installed", Palette.done)
        case .signedOut?: return ("signed out", Palette.ask)
        case .missing?: return ("not installed", Palette.textTertiary)
        case nil: return ("checking", Palette.textTertiary)
        }
    }

    /// An island for each chosen project, two tiles each, up to four islands.
    private mutating func placeProjects() {
        if case .zooming(let landing)? = onboarding.finishing { return placeLanding(landing) }
        tiles = Array(repeating: parked, count: Ghost.all.count)
        let chosen = Array(onboarding.chosenProjects.prefix(4))
        guard !chosen.isEmpty else {
            emptyMessage = "Your projects land here"
            return
        }
        let islandWidth = 2 * tile.width + gap
        let islandHeight = tile.height + labelSpace
        let columns = min(2, chosen.count)
        let rows = (chosen.count + 1) / 2
        let spacing = CGSize(width: 64, height: 48)
        let totalWidth = Double(columns) * islandWidth + Double(columns - 1) * spacing.width
        let totalHeight = Double(rows) * islandHeight + Double(rows - 1) * spacing.height
        let origin = CGPoint(x: region.midX - totalWidth / 2, y: region.midY - totalHeight / 2)
        for (index, choice) in chosen.enumerated() {
            let x = origin.x + Double(index % 2) * (islandWidth + spacing.width)
            let y = origin.y + Double(index / 2) * (islandHeight + spacing.height)
            let swatch = ProjectSwatch.allCases[index % ProjectSwatch.allCases.count]
            labels.append(SceneLabel(id: "project-\(choice.url.path(percentEncoded: false))", text: choice.name, origin: CGPoint(x: x, y: y), swatch: swatch))
            for slot in 0..<2 {
                let frame = CGRect(x: x + Double(slot) * (tile.width + gap), y: y + labelSpace, width: tile.width, height: tile.height)
                tiles[index * 2 + slot] = GhostPlacement(frame: screen(frame), project: choice.name, swatch: swatch)
            }
        }
    }

    /// Done's zoom: labels settle onto the real piles' labels and the sample tiles fade into the
    /// places they stand in for, or into the launcher when the desktop will be empty.
    private mutating func placeLanding(_ landing: OnboardingLanding) {
        let centre = CGRect(x: desktop.width / 2 - tile.width / 4, y: desktop.height / 2 - tile.height / 4, width: tile.width / 2, height: tile.height / 2)
        tiles = Array(repeating: GhostPlacement(frame: screen(centre), opacity: 0), count: Ghost.all.count)
        guard case .projects(let places) = landing else { return }
        for (index, choice) in onboarding.chosenProjects.prefix(4).enumerated() {
            guard let place = places[choice.url.standardizedFileURL] else { continue }
            let swatch = ProjectSwatch.allCases[index % ProjectSwatch.allCases.count]
            let id = "project-\(choice.url.path(percentEncoded: false))"
            // The pile's label is centred on its pile; this is about as wide as it, swatch and all.
            let width = 22 + 7.5 * Double(choice.name.count)
            labels.append(SceneLabel(id: id, text: choice.name, origin: CGPoint(x: place.header.x - width / 2, y: place.header.y), swatch: swatch, size: 0.5))
            for slot in 0..<2 {
                tiles[index * 2 + slot] = GhostPlacement(frame: screen(place.cards), opacity: 0, project: choice.name, swatch: swatch)
            }
        }
    }

    /// Whether Done's zoom lands on projects, so the labels and the sidebar carry on to the end.
    var landsOnProjects: Bool {
        guard case .zooming(into: .projects)? = onboarding.finishing else { return false }
        return true
    }

    /// One large tile showing what a new session starts with; the rest wait behind it.
    private mutating func placeSample() {
        tiles = Array(repeating: parked, count: Ghost.all.count)
        // No bigger on screen than it's drawn, as a tile scaled up past its design size goes soft.
        let shown = layout.desktopRect(expanded: onboarding.zoomsIntoDesktop).width / desktop.width
        let width = min(region.width * 0.62, 760, Ghost.designSize.width / max(shown, 0.01))
        let size = CGSize(width: width, height: width * 0.6)
        let frame = CGRect(x: region.midX - size.width / 2, y: region.midY - size.height / 2 + 16, width: size.width, height: size.height)
        let project = onboarding.chosenProjects.first?.name ?? "ledger"
        tiles[0] = GhostPlacement(frame: screen(frame), project: project, swatch: .sage, isSample: true)
        labels.append(SceneLabel(id: "project-sample", text: project, origin: CGPoint(x: frame.minX, y: frame.minY - labelSpace), swatch: .sage))
    }

    /// A pile per project, each a slightly untidy stack, for trying the keys and seeing a blocked
    /// session rise to the top of its pile.
    private mutating func placePiles(focus: Int?) {
        tiles = Array(repeating: parked, count: Ghost.all.count)
        let piles = Onboarding.tutorialPiles
        let spacing = 56.0
        let width = min(tile.width * 1.15, (region.width - Double(piles.count - 1) * spacing) / Double(piles.count))
        let size = CGSize(width: width, height: width * 0.6)
        let totalWidth = Double(piles.count) * size.width + Double(piles.count - 1) * spacing
        let origin = CGPoint(x: region.midX - totalWidth / 2, y: region.midY - size.height / 2 + 16)
        // The piles belong to the projects you chose, so they match the sidebar.
        let chosen = Array(onboarding.chosenProjects.prefix(piles.count))
        // How the card behind each top is knocked out of square: a few points and a turn.
        let behind: [(x: Double, y: Double, tilt: Double)] = [(16, -12, 3.5), (-14, -13, -3), (15, 12, 3)]
        for (index, cards) in piles.enumerated() {
            let x = origin.x + Double(index) * (size.width + spacing)
            func ownerOf(_ pile: Int) -> Int? { chosen.isEmpty ? nil : pile * chosen.count / piles.count }
            let owner = ownerOf(index)
            if let owner, index == 0 || ownerOf(index - 1) != owner {
                labels.append(SceneLabel(
                    id: "project-\(chosen[owner].url.path(percentEncoded: false))", text: chosen[owner].name,
                    origin: CGPoint(x: x, y: origin.y - labelSpace), swatch: ProjectSwatch.allCases[owner % ProjectSwatch.allCases.count]
                ))
            }
            let top = onboarding.step == .keyboard ? onboarding.tutorialTop(of: index) : cards[0]
            for ghost in cards {
                let isTop = ghost == top
                let knock = behind[index % behind.count]
                let frame = CGRect(x: x + (isTop ? 0 : knock.x), y: origin.y + (isTop ? 0 : knock.y), width: size.width, height: size.height)
                var placement = GhostPlacement(frame: screen(frame), project: Ghost.all[ghost].project, tilt: isTop ? 0 : knock.tilt, layer: isTop ? 1 : 0)
                if let owner {
                    placement.project = chosen[owner].name
                    placement.swatch = ProjectSwatch.allCases[owner % ProjectSwatch.allCases.count]
                }
                if isTop { placement.pileCount = cards.count }
                if onboarding.step == .keyboard, isTop {
                    placement.isFocused = focus == index
                    if onboarding.showsDigitHints { placement.badge = "\(index + 1)" }
                }
                tiles[ghost] = placement
            }
        }
    }

    // MARK: Screen positions

    func labelOrigin(_ label: SceneLabel) -> CGPoint { screen(label.origin) }

    var scale: Double { layout.desktopRect(expanded: onboarding.zoomsIntoDesktop).width / desktop.width }

    var bannerFrame: CGRect {
        screen(CGRect(x: desktop.width - 576, y: 20, width: 556, height: 556 * 76 / 360))
    }
}

/// Where the column and the miniature sit on screen.
struct OnboardingLayout: Equatable {
    let size: CGSize

    static let columnWidth = 460.0

    var contentWidth: Double { min(size.width - 128, 1440) }
    var gap: Double { contentWidth < 1060 ? 48 : 88 }
    var columnX: Double { (size.width - contentWidth) / 2 }

    /// The miniature desktop: the screen's shape, to the right of the column. Expanded, the screen.
    func desktopRect(expanded: Bool) -> CGRect {
        if expanded { return CGRect(origin: .zero, size: size) }
        let available = contentWidth - Self.columnWidth - gap
        let aspect = size.height / max(size.width, 1)
        let height = min(available * aspect, size.height * 0.6)
        let width = height / aspect
        let x = columnX + Self.columnWidth + gap + (available - width) / 2
        return CGRect(x: x, y: (size.height - height) / 2, width: width, height: height)
    }
}
