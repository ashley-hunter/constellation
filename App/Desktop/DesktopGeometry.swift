import ConstellationCore
import CoreGraphics

/// Where the cards sit on the desktop, in desktop points. Core lays out the piles (`PilesLayout`);
/// this adds the rings, reading order and focus geometry.
struct DesktopGeometry {
    /// Kept clear on the left for the sidebar, when it shows.
    static let sidebarClearance = 296.0
    static let trailingMargin = 32.0

    private(set) var tileFrames: [TileItem: CGRect] = [:]
    /// Cards in reading order, for focusing the first one.
    private(set) var orderedItems: [TileItem] = []
    /// The top card of the pile each card behind sits in.
    private(set) var stackOwners: [TileItem: TileItem] = [:]
    /// Each pile of more than one as a ring, by its top card: the top, then the cards behind in order.
    private(set) var stacks: [TileItem: [TileItem]] = [:]
    /// The cards keys move between and badge: each pile's top card in reading order, or the cards
    /// of the pile fanned out.
    private(set) var targets: [TileItem] = []
    /// The piles as drawn.
    let piles: PilesLayout

    /// The desktop as one screen of piles. A pile is a ring: its top card stands for it, and the
    /// cards behind turn to the top as they are focused.
    init(piles layout: PilesLayout) {
        piles = layout
        tileFrames = layout.frames
        orderedItems = layout.cards.map(\.item)
        targets = layout.targets
        for ring in layout.rings.values where ring.count > 1 {
            stacks[ring[0]] = ring
            for item in ring.dropFirst() { stackOwners[item] = ring[0] }
        }
    }

    /// The ring of cards in `item`'s pile, when it is in one of more than one.
    func stack(containing item: TileItem) -> [TileItem]? {
        stacks[stackOwners[item] ?? item]
    }

    /// Where a card's jump badge goes: its top-left.
    func badgeOrigin(of item: TileItem) -> CGPoint? {
        tileFrames[item]?.origin
    }

    /// The nearest card in a direction, preferring ones in line with `frame`.
    static func neighbour(of frame: CGRect, in direction: FocusDirection, among frames: [TileItem: CGRect]) -> TileItem? {
        let from = CGPoint(x: frame.midX, y: frame.midY)
        let scored = frames.compactMap { item, candidate -> (TileItem, Double)? in
            let dx = candidate.midX - from.x
            let dy = candidate.midY - from.y
            let (along, across): (Double, Double) = switch direction {
            case .left: (-dx, dy)
            case .right: (dx, dy)
            case .up: (-dy, dx)
            case .down: (dy, dx)
            }
            guard along > 1 else { return nil }
            return (item, along + 2 * abs(across))
        }
        return scored.min { $0.1 < $1.1 }?.0
    }
}
