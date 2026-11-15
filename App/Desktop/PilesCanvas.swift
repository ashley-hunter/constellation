import AppKit
import ConstellationCore
import SwiftUI

/// The Piles desktop: every pile on one screen, each where you put it, with no scrolling.
/// A terminal's card is laid out afresh for every step of a move (see `PlacedCard`), so its live
/// shell slides with the rest. Frames all come from the model's geometry, never from a measured frame.
struct PilesCanvas: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let geometry = model.geometry
        let layout = geometry.piles
        let cards = layout.cards
        let depths = layout.rings.mapValues(\.count)
        let states = Dictionary(grouping: cards, by: \.pile).mapValues { PileCount.states(of: $0.map(\.rank)) }
        let branches = Dictionary(layout.labels.map { ($0.pile, $0.branch) }) { first, _ in first }
        let spreadArea = model.spreadPile.map { spread in
            cards.filter { $0.pile == spread && $0.role == .fanned }.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        } ?? .null
        let badges = model.jumpBadges(in: geometry)
        ZStack(alignment: .topLeading) {
            // The whole screen, so a click between piles gathers a fan or clears focus.
            Color.clear
                .contentShape(.rect)
                .onTapGesture { model.tapPilesBackground() }
                .zIndex(-1)
            ForEach(layout.labels, id: \.pile) { label in
                PileLabelView(label: label, isReceded: model.showsLauncher || (model.spreadPile.map { $0 != label.pile } ?? false))
                    .zIndex(label.z)
            }
            ForEach(cards, id: \.item) { card in
                // The draft the launcher is opening lives in its panel until it is kept or started.
                if card.item != model.launcher.launch.map({ .session($0.draftID) }) {
                    PileCardView(card: card, depth: depths[card.pile] ?? 1, states: states[card.pile] ?? [], look: look(of: card), blur: blur(of: card, under: spreadArea), badges: badges[card.item] ?? JumpBadges())
                        .environment(\.pileBranch, branches[card.pile])
                        .zIndex(card.z)
                }
            }
            if let spread = model.spreadPile, !spreadArea.isNull {
                // The spread cards and the gaps between them count as the pile, so the pointer
                // crossing a gap doesn't gather it and start it opening again.
                Color.clear
                    .contentShape(.rect)
                    .frame(width: spreadArea.width, height: spreadArea.height)
                    .offset(x: spreadArea.minX, y: spreadArea.minY)
                    .onHover { model.hoverPile(spread, inside: $0) }
                    .onTapGesture { model.tapPilesBackground() }
                    .zIndex(250_001)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Cards reorder and the piles re-flow on the layout spring, unless the change came with its
        // own (a fan, a drop, the sidebar), so one change moves on one spring. Nothing springs when
        // animations are off, as for the first real size at launch.
        .transaction(value: RestKey(cards: layout.rings, places: layout.places, bounds: layout.bounds, turned: turnedFront(in: geometry))) { transaction in
            if transaction.animation == nil, !transaction.disablesAnimations { transaction.animation = .layout }
        }
        // A pile new to the desktop keeps the place it was given.
        .onChange(of: layout.places, initial: true) { model.rememberPilePlaces(model.geometry.piles) }
        // The first layout may come before the desktop's real size, when places can't be saved yet.
        .onChange(of: model.pilesBounds) { model.rememberPilePlaces(model.geometry.piles) }
        .onChange(of: model.keyboard.showsDigitHints) { _, shown in model.commandHintsChanged(shown) }
    }

    /// Where the piles rest and the order of their cards, so only a change that moves something
    /// brings the layout spring (not a card's state or a pile's branch changing).
    private struct RestKey: Hashable {
        let cards: [Pile.ID: [TileItem]]
        let places: [Pile.ID: CGRect]
        let bounds: CGRect
        let turned: TileItem?
    }

    /// The focused card, when it has turned its pile.
    private func turnedFront(in geometry: DesktopGeometry) -> TileItem? {
        guard let focused = model.focusedItem, let ring = geometry.stack(containing: focused), ring.first != focused else { return nil }
        return focused
    }

    /// Cards under a spread pile go soft, most in the middle of the spread and not at all past a
    /// margin around it, by blurring the cards themselves: nothing is laid over them, so no colour.
    private func blur(of card: PilesLayout.Card, under area: CGRect) -> Double {
        guard !area.isNull, card.role != .fanned else { return 0 }
        let margin = 60.0
        // From the card's nearest edge, so only cards actually under or right beside the spread soften.
        let dx = max(area.minX - card.frame.maxX, 0, card.frame.minX - area.maxX)
        let dy = max(area.minY - card.frame.maxY, 0, card.frame.minY - area.maxY)
        let distance = (dx * dx + dy * dy).squareRoot()
        return 3 * max(0, 1 - distance / margin)
    }

    /// How strongly a card draws: the Settled tray at 55%, and under the lens or behind a fan 22%.
    private func look(of card: PilesLayout.Card) -> CardLook {
        let isFanned = card.role == .fanned
        // Unchanged under an open panel, whose scrim dims everything evenly over it, so nothing
        // brightens behind the scrim and dims again as the panel goes.
        // Spread by a click, a key, ⌘ or the pointer resting on it: the rest of the desktop recedes.
        let outsideFan = model.spreadPile.map { $0 != card.pile } ?? false
        let lensed = model.isLensOn && !card.rank.isLit
        // Only its top card, so a see-through pile doesn't show its cards' text through each other.
        // Under the launcher, which stands over the desktop like a spread pile.
        if outsideFan || lensed || model.showsLauncher { return CardLook(strength: 1, isMuted: false, opacity: card.role == .behind ? 0 : 0.3) }
        // The focused card shows in full, so the veil can't hide its ring.
        if card.pile == .settled, !isFanned, model.focusedItem != card.item { return CardLook(strength: 0.55, isMuted: false) }
        return CardLook(strength: 1, isMuted: false)
    }
}

struct CardLook: Equatable {
    /// How much of the card shows through the veil that dims it, 1 for all of it. A veil rather than
    /// transparency, so cards that overlap don't show through each other.
    var strength: Double
    /// Dimmed by the lens or a fan: its colour drains too.
    var isMuted: Bool
    /// Behind a spread pile or the lens the whole card goes see-through, wallpaper and all.
    var opacity: Double = 1
}

/// One card of a pile at its frame. The top card and fanned cards are live; a terminal behind
/// another shows only its title, so its shell isn't drawn where it can't be seen. A card in a
/// spread pile drags to another card's place to reorder the pile.
private struct PileCardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let card: PilesLayout.Card
    /// How many cards its pile has, and how many are in each state that wants a look.
    let depth: Int
    let states: [PileCount.State]
    let look: CardLook
    /// Softness under a spread pile; a live terminal shows its still face while soft, as AppKit
    /// views don't take SwiftUI's blur.
    var blur: Double = 0
    /// Its jump badges, drawn on the card so they ride it as it moves and drifts.
    var badges = JumpBadges()

    var body: some View {
        let showsCount = card.role == .top && depth > 1
        let isShown = card.role == .top || card.role == .fanned
        PlacedCard(frame: card.frame, rotation: card.rotation, isLaidOutEachFrame: holdsShell) { frame in
            TileFace(
                item: card.item,
                floats: card.role != .behind,
                isLive: (card.role == .top && blur == 0) || card.role == .fanned
            )
            // Inside the placed card, so the glow and glint sit round the card rather than its layout
            // box, and under the count so the edge doesn't cross it. None round an opened card's
            // empty place.
            .modifier(StateCue(rank: card.rank, isShown: isShown, isOpened: card.item == model.openedTile || card.item == model.presentingTile))
            // A card behind sits on the one below it rather than floating, so its edges still read.
            .shadow(color: .black.opacity(card.role == .behind ? 0.28 : 0), radius: 2, y: 1)
            // A steady 2pt once scaled, under the count so the ring doesn't cross it.
            .overlay {
                FocusRing(cornerRadius: PanelSurface.cornerRadius, scale: shrink(frame), isOn: TileFace.showsRing(card.item, in: model))
            }
            // On the top right corner's arc; the top left is where jump badges go.
            .overlay(alignment: .topTrailing) {
                // The count spreads the pile and keeps it spread, as a click on a card now opens it.
                if showsCount {
                    PileCount(count: depth, states: states, waitsUnderneath: (states.first { $0.rank == .needsYou }?.count ?? 0) > (card.rank == .needsYou ? 1 : 0))
                        .onTapGesture { model.fanPile(card.pile) }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if card.role == .fanned, card.pile == .settled, case .session = card.item {
                    Button("Unsettle") { model.perform(.sessionUnsettle, on: card.item) }
                        .buttonStyle(ConstellationButtonStyle(weight: .quiet, height: 22))
                        // Over the end of the footer's branch, which it would otherwise sit on.
                        .padding(.leading, 6)
                        .background(Palette.popover)
                        .padding(8)
                        .help("Put it back on its worktree's pile")
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: PanelSurface.cornerRadius, style: .continuous)
                    .fill(Palette.surfaceSunken.opacity((1 - look.strength) * 0.92))
                    .allowsHitTesting(false)
            }
            // Shrunk to a smaller frame, but laid out bigger rather than magnified for a bigger one.
            .environment(\.cardSize, CGSize(width: frame.width / shrink(frame), height: frame.height / shrink(frame)))
            .scaleEffect(shrink(frame), anchor: .topLeading)
            .frame(width: frame.width, height: frame.height, alignment: .topLeading)
            // At full size whatever the card's, like the keys they stand for.
            .overlay(alignment: .topLeading) {
                let inset = CornerChip<EmptyView>.arcInset - 10
                if let top = badges.top {
                    JumpBadge(badge: top).offset(x: inset, y: inset).transition(.opacity)
                }
                // The ⌘-spread pile's letters, at the bottom left, where they were while ⌘ was held.
                if let bottom = badges.bottom {
                    JumpBadge(badge: bottom).offset(x: inset, y: frame.height - CornerChip<EmptyView>.arcInset - 10).transition(.opacity)
                }
            }
            // The whole card, its chips and badges with it.
            .modifier(CardNudge(rank: card.rank, isShown: isShown && card.item != model.presentingTile, isOn: model.settings.wigglesForAttention))
        }
        .modifier(PileDrift(pile: card.pile, isOn: model.drifts(card.role)))
        // Only these looks move on the fan's spring; the card's place keeps whatever spring the
        // change that moved it brought.
        .animation(.fan) { content in
            content
                .saturation(look.isMuted ? 0.3 : 1)
                .compositingGroup()
                .opacity(look.opacity)
                .blur(radius: blur)
        }
        .onTapGesture { model.tapPileCard(card) }
        // In global points, as the card moves with the pointer while it's dragged.
        .gesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .global)
                .onChanged { model.dragCard(card.item, by: $0.translation) }
                .onEnded { model.dropCard(card.item, by: $0.translation) },
            including: card.role == .fanned && depth > 1 ? .all : .subviews
        )
        .onHover { hovering in
            model.noteHover(on: card.item, hovering: hovering)
            model.pointer(over: card.item, in: card.pile, inside: hovering)
            if depth > 1 { model.hoverPile(card.pile, inside: hovering) }
            if hovering || model.focusedItem != card.item {
                model.noteAttention(on: card.item, isActive: hovering)
            }
        }
        .onDrop(of: AppModel.droppableTypes, isTargeted: nil) { providers in
            guard case .session(let id) = card.item else { return false }
            return model.acceptDrop(providers, onto: id, onTile: true)
        }
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96, anchor: centre)))
    }

    /// How far a card is shrunk to fit `frame`: never above 1, as magnified text looks blurry and huge.
    private func shrink(_ frame: CGRect) -> Double {
        min(1, frame.width / TileMetrics.fullSize.width)
    }

    /// A terminal's card, whose live shell is an AppKit view. A browser's card shows a snapshot,
    /// and a note's its text.
    private var holdsShell: Bool {
        guard case .terminal(let id) = card.item, let terminal = model.terminalsByID[id] else { return false }
        return terminal.kind == .shell || terminal.kind == .task
    }

    /// The card's own centre, as the point to scale about: the card is placed by a render offset,
    /// so its layout box sits at the canvas's corner and its middle is far from the card's.
    private var centre: UnitPoint {
        UnitPoint(x: card.frame.midX / max(card.frame.width, 1), y: card.frame.midY / max(card.frame.height, 1))
    }
}

/// A pile's depth, a small count on its top card.
struct PileCount: View {
    /// How many of a pile's cards are in one state that wants a look, and its colour.
    struct State: Hashable {
        let rank: PileRank
        let count: Int

        var colour: Color {
            switch rank {
            case .needsYou: Palette.ask
            case .failed: Palette.error
            case .working: Palette.working
            default: Palette.done
            }
        }
    }

    let count: Int
    /// Waiting, failed, working and finished unseen, most urgent first, each in its colour before
    /// the total, so a stack says what's inside it beyond its top card.
    var states: [State] = []
    /// A card that needs you is under the top one, so a beacon on the badge calls for it.
    var waitsUnderneath = false

    /// The states worth counting among `ranks`, most urgent first; seen and settled cards aren't.
    static func states(of ranks: [PileRank]) -> [State] {
        [PileRank.needsYou, .failed, .working, .unseenDone].compactMap { rank in
            let count = ranks.filter { $0 == rank }.count
            return count > 0 ? State(rank: rank, count: count) : nil
        }
    }

    var body: some View {
        CornerChip(tint: states.first.map { $0.colour.opacity(0.45) } ?? Palette.edge) {
            HStack(spacing: 4) {
                if waitsUnderneath { PileBeacon() }
                Image(systemName: "square.stack").font(.system(size: 9, weight: .semibold))
                ForEach(states, id: \.rank) { state in
                    Text("\(state.count)").foregroundStyle(state.colour)
                }
                if !states.isEmpty { Text("·") }
                Text("\(count)")
            }
            .foregroundStyle(Palette.textSecondary)
        }
        .offset(x: 10 - CornerChip<EmptyView>.arcInset, y: CornerChip<EmptyView>.arcInset - 10)
        .contentShape(.rect)
        .accessibilityLabel(([("\(count) in this pile")] + states.map { "\($0.count) \(Self.name(of: $0.rank))" }).joined(separator: ", "))
    }

    private static func name(of rank: PileRank) -> String {
        switch rank {
        case .needsYou: "need you"
        case .failed: "failed"
        case .working: "working"
        default: "finished"
        }
    }
}

/// The keyboard's ring round a card: 2pt of the focus blue past a dark gap, so it reads on any
/// wallpaper and at any card size. On at once with focus rather than fading in behind the card that
/// just took it, and drawn with the card so it can't trail it while a pile turns.
struct FocusRing: View {
    let cornerRadius: CGFloat
    /// How far the card it's drawn on is shrunk, which the ring's widths undo.
    var scale: CGFloat = 1
    let isOn: Bool

    var body: some View {
        let unit = 1 / max(scale, 0.01)
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius + 3 * unit, style: .continuous)
                .strokeBorder(Palette.surfaceSunken.opacity(0.85), lineWidth: 3 * unit)
                .padding(-3 * unit)
            RoundedRectangle(cornerRadius: cornerRadius + 5 * unit, style: .continuous)
                .strokeBorder(Palette.focus, lineWidth: 2 * unit)
                .padding(-5 * unit)
        }
        .opacity(isOn ? 1 : 0)
        .animation(nil, value: isOn)
        .allowsHitTesting(false)
    }
}

/// An amber dot that sends out a ring every couple of seconds, for a pile hiding a card that needs
/// you. Still with Reduce Motion, and while the app is in the background.
private struct PileBeacon: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(DesktopAppearance.self) private var appearance

    var body: some View {
        Circle()
            .fill(Palette.ask)
            .frame(width: 6, height: 6)
            .background {
                if !reduceMotion, appearance.isActive {
                    Circle()
                        .stroke(Palette.ask, lineWidth: 1.5)
                        .phaseAnimator([false, true]) { ring, out in
                            ring.scaleEffect(out ? 2.6 : 1).opacity(out ? 0 : 0.8)
                        } animation: { out in out ? .easeOut(duration: 1.4).delay(0.9) : .linear(duration: 0.01) }
                }
            }
    }
}

/// A pile's name on the wallpaper under its top card: its project's mark and name then, quieter,
/// the name you gave its worktree or its branch, or "Settled" for the tray. It is the handle that
/// drags the pile to another place; a click spreads the pile instead. While ⌃ is held it shows the
/// project's ⌃ number.
private struct PileLabelView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.wallpaperTone) private var tone
    let label: PilesLayout.Label
    /// Another pile is spread, so this one recedes with its cards.
    let isReceded: Bool

    var body: some View {
        let project = model.project(label.projectID)
        HStack(spacing: 6) {
            if model.keyboard.showsProjectHints, let project, let index = model.projects.firstIndex(of: project), index < 9 {
                KeyChip("⌃\(index + 1)")
                    .transition(.opacity)
            }
            if let project { ProjectMark(project: project) }
            Text(title(in: project))
                .font(.ui(11, weight: .medium))
                .foregroundStyle(tone.primaryText)
                .lineLimit(1)
                .layoutPriority(1)
            if let detail = detail(in: project) {
                Text("· \(detail)")
                    .font(.ui(11))
                    // The primary colour a step back: the secondary one is lost on a bright wallpaper.
                    .foregroundStyle(tone.primaryText.opacity(0.72))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .shadow(color: .black.opacity(tone == .dark ? 0.45 : 0), radius: 6, y: 1)
        .padding(.horizontal, 6)
        .frame(height: label.frame.height)
        .modifier(PileDrift(pile: label.pile, isOn: model.drifts(.top)))
        .contentShape(.rect)
        // In Exposé the Settled tray always comes last, so it has nothing to drag.
        .pointerStyle(isFixed ? nil : .grabIdle)
        .onTapGesture { model.fanPile(label.pile) }
        // In global points, as the label moves with the pointer while it's dragged.
        .gesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .onChanged { model.dragPile(label.pile, by: $0.translation) }
                .onEnded { model.dropPile(label.pile, by: $0.translation) }
        )
        .frame(width: label.frame.width)
        .offset(x: label.frame.minX, y: label.frame.minY)
        // Only its fade on the fan's spring, so it moves with its cards on theirs.
        .animation(.fan) { $0.opacity(label.isShown ? (isReceded ? 0.3 : 1) : 0) }
        .allowsHitTesting(label.isShown)
        .help(help)
        .contextMenu {
            if let folder = worktreeFolder(in: project) {
                Button("Rename worktree…") { model.promptRenameWorktree(folder) }
            }
        }
    }

    private var isFixed: Bool {
        label.pile == .settled && model.settings.desktopArrangement == .expose
    }

    private var help: String {
        let hint = switch (label.pile, model.settings.desktopArrangement) {
        // In Exposé the tray always comes last.
        case (.settled, .expose): "Click to spread the Settled tray"
        case (.settled, .grid): "Drag to move the Settled tray"
        default: "Drag to move this pile; click to spread it"
        }
        // The full branch, which the worktree's name or the shortened one hides.
        guard case .worktree = label.pile, !label.branch.isEmpty else { return hint }
        return "\(label.branch)\n\(hint)"
    }

    /// A worktree pile's folder, nil for the project's own checkout and the Settled tray.
    private func worktreeFolder(in project: Project?) -> String? {
        guard case .worktree(let folder) = label.pile, folder != project.map({ Piles.folder($0.rootPath) }) else { return nil }
        return folder
    }

    /// The project's name, or "Settled" for the tray; the folder's name when the project is gone.
    private func title(in project: Project?) -> String {
        switch label.pile {
        case .settled:
            "Settled"
        case .worktree(let folder):
            project?.name ?? URL(filePath: folder).lastPathComponent
        }
    }

    /// After the project's name: the worktree's name, else its branch without prefixes or request
    /// words. Nil on the default branch or while it holds only drafts.
    private func detail(in project: Project?) -> String? {
        if let folder = worktreeFolder(in: project), let name = model.worktreeName(of: folder) { return name }
        guard case .worktree = label.pile else { return nil }
        return Session.labelBranch(label.branch, defaultBranch: project?.defaultBranch)
    }
}

/// A card placed at its frame and turned by its rotation. A card that can hold a live shell (an
/// AppKit view, which doesn't follow SwiftUI's animations) is laid out afresh for every step of a
/// move, so the shell slides and turns with its card instead of jumping to the end. Every other card
/// is laid out once at its new frame and moved there by render effects alone, so a move doesn't
/// rebuild it every frame.
private struct PlacedCard<Content: View>: View, Animatable {
    var frame: CGRect
    var rotation: Double
    let isLaidOutEachFrame: Bool
    @ViewBuilder let content: (CGRect) -> Content

    /// Nothing to step through for a card moved by render effects, so its body runs once a move.
    nonisolated var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<AnimatablePair<CGFloat, CGFloat>, Double>> {
        get {
            guard isLaidOutEachFrame else { return .zero }
            return AnimatablePair(AnimatablePair(frame.minX, frame.minY), AnimatablePair(AnimatablePair(frame.width, frame.height), rotation))
        }
        set {
            guard isLaidOutEachFrame else { return }
            frame = CGRect(x: newValue.first.first, y: newValue.first.second, width: newValue.second.first.first, height: newValue.second.first.second)
            rotation = newValue.second.second
        }
    }

    var body: some View {
        content(frame)
            .frame(width: frame.width, height: frame.height, alignment: .topLeading)
            .contentShape(.rect)
            .modifier(CardPlacement(origin: frame.origin, rotation: rotation))
    }
}

/// A card's place and turn, stepped through on every frame of a move. Clicks land where a card is
/// drawn rather than where it is going, so a click on a pile as it spreads or turns opens the card
/// under the pointer. Only these effects step; the card inside isn't rebuilt.
private struct CardPlacement: ViewModifier, Animatable {
    var origin: CGPoint
    var rotation: Double

    nonisolated var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, Double> {
        get { AnimatablePair(AnimatablePair(origin.x, origin.y), rotation) }
        set {
            origin = CGPoint(x: newValue.first.first, y: newValue.first.second)
            rotation = newValue.second
        }
    }

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(rotation))
            .offset(x: origin.x, y: origin.y)
    }
}
