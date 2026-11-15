import ConstellationCore
import SwiftUI

/// A card's face at full size: its view, or the placeholder its opened panel left, with the
/// session's in-place answer and inline composer over it, and the focus ring. The caller scales it to
/// the card's frame, so the ring shrinks with the card rather than showing as a full-size ghost.
struct TileFace: View {
    @Environment(AppModel.self) private var model
    @Environment(\.cardSize) private var size
    let item: TileItem
    /// Off for a card behind another, whose float shadow would read as one more card below.
    var floats = true
    /// Off for a terminal card whose shell isn't worth drawing live: behind another, or shrunk.
    var isLive = true
    /// Drawn over its own panel as it grows or shrinks (see `PresentationEffect`), so it shows its
    /// face rather than the empty place an opened card leaves.
    var isStandIn = false

    var body: some View {
        let height = size.height
        Group {
            if isOpened {
                OpenedTilePlaceholder()
            } else {
                TileView(item: item, floats: floats, isLive: isLive)
            }
        }
        .frame(width: size.width, height: height, alignment: .topLeading)
        .environment(\.showsCardKeys, model.focusedItem == item)
        .overlay(alignment: .bottom) {
            // Not on an opened tile, whose panel holds the answers instead. A waiting card always
            // shows what it's asking; a failed one only once it's focused.
            if !isOpened, let session = model.session(for: item), InPlaceAnswer.shows(for: session),
               model.focusedItem == item || session.runState == .blocked {
                InPlaceAnswer(session: session)
                    .environment(\.showsCardKeys, model.focusedItem == item)
                    .frame(height: height - TileMetrics.titleBarHeight)
                    .clipped()
            }
        }
        .overlay(alignment: .bottom) {
            if let session = model.session(for: item), model.inlineComposerID == session.id {
                ChatComposer(session: session, style: .inline, focusOnAppear: true)
                    .padding(8)
                    .transition(.opacity)
            }
        }
    }

    /// Whether `item`'s card shows the focus ring (see `FocusRing`): an opened tile is hidden or
    /// covered by its panel, and a draft being discarded is leaving, so neither does.
    static func showsRing(_ item: TileItem, in model: AppModel) -> Bool {
        model.focusedItem == item && item != model.openedTile && item != model.presentingTile
            && model.session(for: item).map { $0.id == model.discardingDraftID } != true
    }

    /// The opened session's, draft's or terminal's tile, which its panel stands in for from the
    /// moment it starts opening until it has finished closing, so the two never show at once.
    private var isOpened: Bool {
        !isStandIn && (item == model.openedTile || item == model.presentingTile)
    }
}

/// Where an opened session or terminal was: its panel grew out of here and shrinks back into the
/// empty place.
struct OpenedTilePlaceholder: View {
    var body: some View {
        Color.clear
    }
}
