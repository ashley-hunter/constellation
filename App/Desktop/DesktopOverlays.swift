import ConstellationCore
import SwiftUI

/// Sheets, the opened terminal and the session view over the desktop. Each opens and closes on a
/// spring that can be turned around mid-flight; see `OverlayPresenter`.
struct DesktopOverlays: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Start grows the draft panel into its session view.
    @Namespace private var draftMorph

    var body: some View {
        GeometryReader { proxy in
            overlays(in: proxy.size)
        }
    }

    private func overlays(in size: CGSize) -> some View {
        ZStack {
            if let notice = model.notices.notice {
                NoticeBanner(text: notice.text, undo: model.canUndoNotice ? { model.undoNotice() } : nil) { model.expireNotice(notice.id) }
                    // Each notice its own timer, even one that repeats the text before it.
                    .id(notice.id)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 16)
                    // A short drop and a fade: the banner's box is the whole height, so a move from
                    // the top edge would send it down the screen.
                    .transition(reduceMotion ? .opacity : .offset(y: -8).combined(with: .opacity))
            }
            OverlayPresenter(item: model.grid == nil && model.gridPicking == nil ? nil : GridSlot.grid) {
                if model.gridPicking != nil { model.endGridPicking() } else { model.closeGrid() }
            } content: { _ in
                SessionGridView(size: size)
            }
            openedTileSlot(in: size)
            OverlayPresenter(item: model.sheet) {
                model.dismissSheet()
            } content: { sheet in
                switch sheet {
                case .cleanup:
                    CleanupSheet()
                case .palette(let text):
                    CommandPalette(text: text)
                case .git(let action, let id):
                    if let session = model.sessionsByID[id] {
                        GitSheet(session: session, action: action)
                    }
                case .projects(let flow):
                    CommandPalette(text: "", flow: flow)
                }
            }
            OverlayPresenter(item: model.zoomedAttachment) {
                model.zoomedAttachment = nil
            } content: { attachment in
                AttachmentZoom(attachment: attachment)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.hover, value: model.notice)
    }

    /// The opened session, draft or terminal: one slot, so they all open and close the same way. A
    /// draft keeps its slot when it starts, so its panel morphs into the session view in place.
    private func openedTileSlot(in size: CGSize) -> some View {
        OverlayPresenter(
            // Not a session in the split screen, which shows in its tile.
            item: model.soloOpenedTile,
            // Over the launcher there's nothing to dim, and the launcher stays showing while the
            // panel leaves, so the scrim doesn't flash in on the way out.
            dims: { item in model.session(for: item)?.isDraft != true || !model.showsLauncher },
            dismiss: { model.goBack() },
            style: { item in style(for: item, in: size) },
            // A draft's card is a plain stand-in for its composer, which fades in on its own.
            standIn: { item in
                guard model.session(for: item)?.isDraft != true, gridHalf(for: item, in: size) == nil else { return nil }
                // Set up as its card on the desktop is, so the face it shrinks into is the card's.
                let pile = model.pileID(of: item)
                let branch = model.geometry.piles.labels.first { $0.pile == pile }?.branch
                return AnyView(TileFace(item: item, floats: false, isLive: false, isStandIn: true)
                    .environment(\.pileBranch, branch)
                    .environment(model))
            },
            presented: { item in model.startPresenting(item) },
            closed: { item in model.finishClosing(item) }
        ) { item in
            let frame = panelFrame(for: item, in: size)
            switch item {
            case .session(let id):
                if let session = model.sessionsByID[id] {
                    if session.isDraft {
                        DraftOverlay(session: session, morph: draftMorph)
                            .transition(.opacity)
                    } else {
                        SessionView(session: session)
                            .frame(width: frame.width, height: frame.height)
                            .matchedGeometryEffect(id: session.id, in: draftMorph)
                            .position(x: frame.midX, y: frame.midY)
                            .transition(.opacity)
                    }
                }
            case .terminal(let id):
                if let terminal = model.terminalsByID[id] {
                    Group {
                        switch terminal.kind {
                        case .browser: OpenedBrowserPanel(browser: terminal)
                        case .note: OpenedNotePanel(note: terminal)
                        case .shell, .task: OpenedTerminalPanel(terminal: terminal)
                        }
                    }
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                }
            }
        }
        .animation(.present, value: model.openedSessionID.flatMap { model.sessionsByID[$0]?.isDraft })
    }

    /// Where the opened tile's panel sits in a container of `size`, from layout alone: its own
    /// size, or the whole desktop when its kind is maximised.
    private func panelFrame(for item: TileItem, in size: CGSize) -> CGRect {
        switch item {
        case .session(let id):
            guard model.sessionsByID[id]?.isDraft == true else {
                return model.isMaximised(.session) ? model.maximisedFrame(in: size) : SessionView.frame(in: size, showsDetail: model.sessionDetail != nil)
            }
            // Where `DraftOverlay` puts it; its height follows the composer, so the hero's clip
            // reaches past its foot rather than cutting it off.
            let top = max(40, size.height * 0.2)
            return CGRect(x: ((size.width - DraftPanel.width) / 2).rounded(), y: top, width: DraftPanel.width, height: max(size.height - top - 40, 0))
        case .terminal(let id):
            let kind = model.terminalsByID[id].map(PanelKind.init) ?? .terminal
            if model.isMaximised(kind) { return model.maximisedFrame(in: size) }
            return switch kind {
            case .browser: OpenedBrowserPanel.frame(in: size)
            case .note: OpenedNotePanel.frame(in: size)
            default: OpenedTerminalPanel.frame(in: size)
            }
        }
    }

    /// The opened tile grows out of its card and shrinks back into it. A draft pops in, and a draft
    /// started from its panel morphs from the panel instead, but both shrink into their card on the
    /// way out once they have one. Anything with no card on screen pops in.
    private func style(for item: TileItem, in size: CGSize) -> PresentationStyle {
        let isClosing = model.openedTile != item
        if case .session(let id) = item, !isClosing, model.sessionsByID[id]?.isDraft != false || model.startedDraftID == id {
            return .popin
        }
        // Going into the split screen or back out of it, it moves between its half and its own place.
        if let half = gridHalf(for: item, in: size) { return .hero(from: half, to: panelFrame(for: item, in: size)) }
        // The desktop never scrolls, so a card's frame is already where it is on screen.
        guard let tile = model.geometry.tileFrames[item] else { return .popin }
        return .hero(from: tile, to: panelFrame(for: item, in: size))
    }
}

extension DesktopOverlays {
    /// The tile a session holds in the split screen, or held as it was being made, when it goes
    /// between there and its own view.
    private func gridHalf(for item: TileItem, in size: CGSize) -> CGRect? {
        guard case .session(let id) = item else { return nil }
        let bounds = model.maximisedFrame(in: size)
        if model.gridHolds(id) {
            return GridLayout(grid: model.grid, picking: model.gridPicking, in: bounds).tiles.first { $0.id == id }?.frame
        }
        guard model.gridReturnID == id, model.grid == nil, model.gridPicking == nil else { return nil }
        return SessionGrid.frames(count: 2, in: bounds, gap: SessionGridView.gap).first
    }
}

/// The split screen's one slot, which pops in and out as a whole.
private enum GridSlot: Hashable {
    case grid
}

private struct NoticeBanner: View {
    @Environment(AppModel.self) private var model
    let text: String
    let undo: (() -> Void)?
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(text).font(.ui(13)).foregroundStyle(Palette.text).lineLimit(2)
            if let undo {
                Button(action: undo) { KeyedLabel("Undo", key: model.binding(for: .noticeUndo)?.label ?? "") }
                    .buttonStyle(ConstellationButtonStyle(weight: .secondary, height: 22))
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, undo == nil ? 16 : 8)
        .padding(.vertical, 8)
        .panelSurface(.card, cornerRadius: Radius.inner)
        .task {
            try? await Task.sleep(for: NoticeTiming.shown)
            dismiss()
        }
    }
}

enum NoticeTiming {
    /// How long a notice shows, and so how long an Undo has.
    static let shown = Duration.seconds(8)
}
