import CoreGraphics
import Foundation

/// How the desktop sets out its piles, chosen in Settings.
public enum PileArrangement: String, CaseIterable, Hashable, Sendable {
    /// Rows like Mission Control: the piles in their order, as big as the screen lets them be.
    case expose
    /// Rows of equal slots.
    case grid
}

/// What the desktop is doing to its piles: which card is in front, what is peeked or fanned, and
/// what is being dragged.
public struct PilesState: Hashable, Sendable {
    /// The focused card: its pile turns like a ring of cards to bring it to the top.
    public var front: TileItem?
    /// The pile spread into full cards under the pointer.
    public var hovered: Pile.ID?
    /// The pile spread into a row of full cards.
    public var fannedPile: Pile.ID?
    /// A pile still drawn above the rest while it gathers back from a fan or peek.
    public var raised: Pile.ID?
    /// A pile, or a card in a spread pile, following the pointer.
    public var drag: PileDrag?

    public init(front: TileItem? = nil, hovered: Pile.ID? = nil, fannedPile: Pile.ID? = nil, raised: Pile.ID? = nil, drag: PileDrag? = nil) {
        self.front = front
        self.hovered = hovered
        self.fannedPile = fannedPile
        self.raised = raised
        self.drag = drag
    }
}

/// A pile dragged by its label to another place, or a card dragged to another place in its spread pile.
public struct PileDrag: Hashable, Sendable {
    public enum Subject: Hashable, Sendable {
        case pile(Pile.ID)
        case card(TileItem)
    }

    public var subject: Subject
    /// How far the pointer has moved since the drag began.
    public var offset: CGVector

    public init(_ subject: Subject, offset: CGVector) {
        self.subject = subject
        self.offset = offset
    }
}

/// A place on the desktop's grid, counted from the top left.
public struct PileSlot: Hashable, Codable, Sendable {
    public var column: Int
    public var row: Int

    public init(column: Int, row: Int) {
        self.column = column
        self.row = row
    }
}

/// The desktop as a grid of equal slots, each with room for one pile's footprint and its label,
/// centred on the screen.
public struct PileGrid: Hashable, Sendable {
    public var columns: Int
    public var rows: Int
    /// The cards at rest are this fraction of full size.
    public var scale: Double
    /// The top left of the first slot.
    public var origin: CGPoint
    /// One slot: a pile's footprint at this scale with its label below.
    public var slotSize: CGSize
    /// From one slot to the next: a slot and the gap after it.
    public var step: CGSize

    public init(in bounds: CGRect, scale: Double) {
        self.scale = scale
        let gap = CGSize(width: PileMetrics.gap.width * scale, height: PileMetrics.gap.height * scale)
        slotSize = CGSize(width: PileMetrics.footprint.width * scale, height: PileMetrics.footprint.height * scale + PileMetrics.labelHeight)
        step = CGSize(width: slotSize.width + gap.width, height: slotSize.height + gap.height)
        columns = max(1, Int((bounds.width + gap.width) / step.width))
        rows = max(1, Int((bounds.height + gap.height) / step.height))
        let used = CGSize(width: Double(columns) * step.width - gap.width, height: Double(rows) * step.height - gap.height)
        origin = CGPoint(x: (bounds.minX + (bounds.width - used.width) / 2).rounded(), y: (bounds.minY + (bounds.height - used.height) / 2).rounded())
    }

    /// The largest grid, at most full size, with a slot for each of `count` piles. Past the
    /// smallest scale, the piles that don't fit share the last slot.
    public static func fitting(_ count: Int, in bounds: CGRect) -> PileGrid {
        var scale = 1.0
        while scale > PileMetrics.minScale, PileGrid(in: bounds, scale: scale).count < count {
            scale -= 0.02
        }
        return PileGrid(in: bounds, scale: max(scale, PileMetrics.minScale))
    }

    public var count: Int { columns * rows }

    /// Every slot in reading order.
    public var slots: [PileSlot] {
        (0..<rows).flatMap { row in (0..<columns).map { PileSlot(column: $0, row: row) } }
    }

    /// Where the Settled tray goes unless you've moved it.
    public var corner: PileSlot { PileSlot(column: columns - 1, row: rows - 1) }

    public func contains(_ slot: PileSlot) -> Bool {
        (0..<columns).contains(slot.column) && (0..<rows).contains(slot.row)
    }

    public func frame(of slot: PileSlot) -> CGRect {
        CGRect(x: origin.x + Double(slot.column) * step.width, y: origin.y + Double(slot.row) * step.height, width: slotSize.width, height: slotSize.height)
    }

    /// The slot whose middle is nearest `point`, kept on the grid.
    public func nearest(to point: CGPoint) -> PileSlot {
        func index(_ value: Double, from start: Double, size: Double, step: Double, count: Int) -> Int {
            min(max(Int(((value - start - size / 2) / step).rounded()), 0), count - 1)
        }
        return PileSlot(
            column: index(point.x, from: origin.x, size: slotSize.width, step: step.width, count: columns),
            row: index(point.y, from: origin.y, size: slotSize.height, step: step.height, count: rows)
        )
    }

    /// How far apart two slots' middles are, in points.
    func distance(_ a: PileSlot, _ b: PileSlot) -> Double {
        let dx = Double(a.column - b.column) * step.width
        let dy = Double(a.row - b.row) * step.height
        return (dx * dx + dy * dy).squareRoot()
    }
}

/// Where every card and pile label sits on a one-screen desktop of piles. Each pile keeps its
/// place, a slot on a grid or a place in the Exposé order: the one it was given or dragged to,
/// saved and handed back in, so a pile only moves when you move it or others come and go, never
/// because its work changed. Everything comes from the piles, their places, the screen's rectangle
/// and the state, never from what is on screen.
public struct PilesLayout: Hashable, Sendable {
    public struct Card: Hashable, Sendable {
        public enum Role: Hashable, Sendable {
            /// The top of a pile at rest, casting the float shadow.
            case top
            /// Behind the top of a pile, offset and turned a little.
            case behind
            /// Spread out in full in a fanned or hovered pile.
            case fanned
        }

        public var item: TileItem
        public var pile: Pile.ID
        /// Its place in the pile as drawn: 0 on top.
        public var depth: Int
        public var frame: CGRect
        /// Degrees, clockwise.
        public var rotation: Double
        public var z: Double
        public var role: Role
        /// How much it wants you, for the lens.
        public var rank: PileRank
    }

    /// The line under a pile's top card naming it, and the handle that drags it.
    public struct Label: Hashable, Sendable {
        public var pile: Pile.ID
        /// For its colour and ⌃ number.
        public var projectID: UUID?
        /// The branch it names, empty when none of its sessions says.
        public var branch: String
        public var frame: CGRect
        /// Hidden while its pile is spread.
        public var isShown: Bool
        public var z: Double
    }

    public var cards: [Card]
    public var labels: [Label]
    /// The grid the piles sit on; nil in the Exposé arrangement.
    public var grid: PileGrid?
    /// Grid: each pile's slot, including the ones just given to new piles, for saving.
    public var slots: [Pile.ID: PileSlot] = [:]
    /// Exposé: every pile's place in the order, the saved ones not shown just now included and new
    /// ones put in, for saving.
    public var order: [Pile.ID] = []
    /// Each pile's room at rest: its footprint and the label under it.
    public var places: [Pile.ID: CGRect]
    public var bounds: CGRect
    /// The cards at rest are this fraction of full size: on the grid 1 unless nothing else made them
    /// fit; in Exposé as big as fits, up to `PileMetrics.maxScale`.
    public var scale: Double
    /// Cards the keys move between and badge: each pile's top at rest in reading order, or the
    /// fanned cards.
    public var targets: [TileItem]
    /// Each pile's cards in its own order, top first, for turning it like a ring.
    public var rings: [Pile.ID: [TileItem]]

    public var frames: [TileItem: CGRect] { Dictionary(uniqueKeysWithValues: cards.map { ($0.item, $0.frame) }) }
}

/// Sizes and spacing, in points at full size.
public enum PileMetrics {
    public static let card = CGSize(width: TileMetrics.fullSize.width, height: TileMetrics.fullSize.height)
    /// How far a card behind is knocked out from under the top card, either way, so the pile reads
    /// as an untidy stack of photos.
    public static let behindOffset = 4.0...7.0
    /// How far a card behind is turned, in degrees, one way then the other down the pile.
    public static let behindRotation = 2.0...3.5
    /// The most a card behind is turned either way, in degrees.
    public static let maxRotation = behindRotation.upperBound
    /// Cards deeper than this sit square under the top card, out of sight.
    public static let maxVisibleBehind = 3
    /// Kept around the top card for the edges and corners of the cards behind to poke out into:
    /// the largest offset plus what the largest turn pushes a corner out.
    public static let bleed = CGSize(width: 12, height: 15)
    /// A pile's room: one card and its bleed on every side. Piles never share any.
    public static let footprint = CGSize(width: card.width + 2 * bleed.width, height: card.height + 2 * bleed.height)
    /// Between slots, and between piles in Exposé, scaled with the cards.
    public static let gap = CGSize(width: 16, height: 16)
    /// Exposé: between two piles side by side from different projects, scaled with the cards, so a
    /// project's piles read a little as a group.
    public static let projectGap = 32.0
    /// The pile's label under its footprint, the same size at any scale so it stays readable.
    public static let labelHeight = 20.0
    /// The smallest the cards at rest go when the piles don't fit at full size.
    public static let minScale = 0.3
    /// The largest the cards at rest go in Exposé, so one to three piles don't fill the screen. Kept
    /// near full size: a card lays itself out bigger rather than magnifying its text, so past this
    /// it only gains empty space.
    public static let maxScale = 1.2
    /// Between cards in a fanned pile.
    public static let fanGap = 16.0
    /// A spread of up to this many cards blooms round the pile rather than sitting in rows.
    public static let ringLimit = 7
}

extension PilesLayout {
    /// Lays out every pile at rest in its slot inside `bounds`, then applies the hover peek, any
    /// fan and any drag. `saved` is each pile's slot from before; a pile without one, or whose slot
    /// is off the grid or taken, gets one (see `resolve`), returned in `slots` to be saved.
    /// `reserved` are slots kept for piles not shown just now, say while a project filter is on.
    public static func place(
        _ piles: [Pile], slots saved: [Pile.ID: PileSlot] = [:], reserved: Set<PileSlot> = [],
        in bounds: CGRect, state: PilesState = PilesState()
    ) -> PilesLayout {
        let grid = PileGrid.fitting(piles.count, in: bounds)
        let slots = resolve(piles, saved: saved, reserved: reserved, on: grid)
        var layout = PilesLayout(cards: [], labels: [], grid: grid, slots: slots, places: slots.mapValues(grid.frame(of:)), bounds: bounds, scale: grid.scale, targets: [], rings: [:])
        let reading = piles.sorted { a, b in
            let (sa, sb) = (slots[a.id]!, slots[b.id]!)
            return (sa.row, sa.column, a.isSettled ? 1 : 0) < (sb.row, sb.column, b.isSettled ? 1 : 0)
        }
        layout.lay(reading, state: state)
        return layout
    }

    /// Lays out every pile at rest in Exposé rows (see `rows`) in their order, then applies the
    /// hover peek, any fan and any drag. `saved` is the order from before, which may name piles not
    /// shown just now; a pile not in it is put in (see `order`), and the whole order is returned in
    /// `order` to be saved.
    public static func place(_ piles: [Pile], order saved: [Pile.ID], in bounds: CGRect, state: PilesState = PilesState()) -> PilesLayout {
        let order = order(piles, saved: saved)
        let byID = Dictionary(piles.map { ($0.id, $0) }) { first, _ in first }
        let reading = order.compactMap { byID[$0] }
        let (scale, places) = rows(reading, in: bounds)
        var layout = PilesLayout(cards: [], labels: [], grid: nil, order: order, places: places, bounds: bounds, scale: scale, targets: [], rings: [:])
        layout.lay(reading, state: state)
        return layout
    }

    /// Every pile at rest in its place in `reading` order, then the peek, fan and drag `state` asks for.
    private mutating func lay(_ reading: [Pile], state: PilesState) {
        for pile in reading {
            placeAtRest(pile, in: places[pile.id]!, front: state.front)
            rings[pile.id] = pile.cards
        }
        targets = cards.filter { $0.role == .top }.map(\.item)

        if let id = state.fannedPile, let pile = reading.first(where: { $0.id == id }), pile.cards.count > 1 {
            fanPile(pile, in: bounds)
        } else if let id = state.hovered, let pile = reading.first(where: { $0.id == id }), pile.cards.count > 1 {
            // Hover shows the whole pile as full cards, the same as a click fans it, but keys keep
            // reaching every pile: it's a look, not a place you've moved into.
            fanPile(pile, in: bounds, takesTargets: false)
        }
        if let raised = state.raised {
            for index in cards.indices where cards[index].pile == raised && cards[index].role != .fanned {
                cards[index].z += 200_000
            }
        }
        if let drag = state.drag { apply(drag) }
    }

    // MARK: Slots

    /// A slot for every pile. A saved slot on the grid that no pile before it has taken is kept.
    /// The Settled tray goes in the bottom-right corner when it's free. Any other pile goes to the
    /// free slot nearest its project's piles already placed, or the first free one in reading order
    /// when it's its project's first; the tray goes to the free slot nearest the corner. A slot in
    /// `reserved` is only taken when no other is free. Past the smallest scale, piles left with no
    /// free slot share the corner.
    public static func resolve(_ piles: [Pile], saved: [Pile.ID: PileSlot], reserved: Set<PileSlot> = [], on grid: PileGrid) -> [Pile.ID: PileSlot] {
        var slots: [Pile.ID: PileSlot] = [:]
        var taken: Set<PileSlot> = []
        func take(_ slot: PileSlot, for pile: Pile) {
            slots[pile.id] = slot
            taken.insert(slot)
        }
        for pile in piles {
            if let slot = saved[pile.id], grid.contains(slot), !taken.contains(slot) { take(slot, for: pile) }
        }
        if let tray = piles.first(where: \.isSettled), slots[tray.id] == nil, !taken.contains(grid.corner), !reserved.contains(grid.corner) {
            take(grid.corner, for: tray)
        }
        let order = grid.slots
        for pile in piles where slots[pile.id] == nil {
            let open = order.filter { !taken.contains($0) }
            let unreserved = open.filter { !reserved.contains($0) }
            let free = unreserved.isEmpty ? open : unreserved
            guard !free.isEmpty else {
                slots[pile.id] = grid.corner
                continue
            }
            let anchors = pile.isSettled
                ? [grid.corner]
                : piles.filter { $0.projectID != nil && $0.projectID == pile.projectID }.compactMap { slots[$0.id] }
            // `free` is in reading order and `min` keeps the first of equals, so ties go to reading order.
            let slot = anchors.isEmpty ? free[0] : free.min { a, b in
                anchors.map { grid.distance($0, a) }.min()! < anchors.map { grid.distance($0, b) }.min()!
            }!
            take(slot, for: pile)
        }
        return slots
    }

    /// `slots` with `pile` moved to `slot`, swapping places with the pile already there.
    public static func moving(_ pile: Pile.ID, to slot: PileSlot, in slots: [Pile.ID: PileSlot]) -> [Pile.ID: PileSlot] {
        var slots = slots
        guard let from = slots[pile], from != slot else { return slots }
        if let other = slots.first(where: { $0.key != pile && $0.value == slot })?.key { slots[other] = from }
        slots[pile] = slot
        return slots
    }

    // MARK: Exposé

    /// Every pile in order: `saved` as it was, piles not shown just now kept in their places, then
    /// each pile it doesn't name, oldest first, just after the last shown pile of its own project,
    /// or at the end when it's its project's first. The Settled tray always comes last.
    public static func order(_ piles: [Pile], saved: [Pile.ID]) -> [Pile.ID] {
        var order: [Pile.ID] = []
        for id in saved where id != .settled && !order.contains(id) { order.append(id) }
        let project = Dictionary(piles.map { ($0.id, $0.projectID) }) { first, _ in first }
        for pile in piles where !pile.isSettled && !order.contains(pile.id) {
            let last = pile.projectID.flatMap { id in order.lastIndex { project[$0] == id } }
            order.insert(pile.id, at: last.map { $0 + 1 } ?? order.endIndex)
        }
        if piles.contains(where: \.isSettled) { order.append(.settled) }
        return order
    }

    /// Each pile's room in `reading` order, filled into rows left to right and top to bottom, and the
    /// one scale they share. Of every count of rows, each row holding the same number of piles give
    /// or take one, the one where the piles come out largest wins, at most `maxScale`, the fewest
    /// rows on a tie. Gaps scale with the cards, a wider one between piles of different projects;
    /// labels keep their height. Rows are centred across `bounds` and the block of them down it.
    /// Past `minScale`, the rows that fit at it take the piles, each row squeezed to fit across.
    static func rows(_ reading: [Pile], in bounds: CGRect) -> (scale: Double, places: [Pile.ID: CGRect]) {
        let count = reading.count
        guard count > 0 else { return (1, [:]) }
        let full = PileMetrics.footprint
        let label = PileMetrics.labelHeight
        let rowGap = PileMetrics.gap.height
        // After each pile, the gap to the next one in its row, in points at full size.
        let after = reading.indices.map { index in
            index + 1 < count && reading[index + 1].projectID == reading[index].projectID ? PileMetrics.gap.width : PileMetrics.projectGap
        }
        /// How many piles each of `rows` rows takes, the extra ones in the top rows.
        func split(into rows: Int) -> [Range<Int>] {
            let (base, extra) = count.quotientAndRemainder(dividingBy: rows)
            var start = 0
            return (0..<rows).map { row in
                let end = start + base + (row < extra ? 1 : 0)
                defer { start = end }
                return start..<end
            }
        }
        func width(of row: Range<Int>) -> Double {
            Double(row.count) * full.width + row.dropLast().map { after[$0] }.reduce(0, +)
        }
        func height(_ rows: Int, at scale: Double) -> Double {
            Double(rows) * (full.height * scale + label) + Double(rows - 1) * rowGap * scale
        }

        var best: (rows: Int, scale: Double)?
        for rows in 1...count {
            let across = bounds.width / split(into: rows).map(width).max()!
            let down = (bounds.height - Double(rows) * label) / (Double(rows) * full.height + Double(rows - 1) * rowGap)
            let scale = min(across, down, PileMetrics.maxScale)
            if scale > best?.scale ?? 0 { best = (rows, scale) }
        }
        var rows = best?.rows ?? 1
        var scale = best?.scale ?? 0
        if scale < PileMetrics.minScale {
            scale = PileMetrics.minScale
            rows = min(count, max(1, Int((bounds.height + rowGap * scale) / (full.height * scale + label + rowGap * scale))))
        }

        let room = CGSize(width: full.width * scale, height: full.height * scale + label)
        var places: [Pile.ID: CGRect] = [:]
        var y = bounds.minY + (bounds.height - height(rows, at: scale)) / 2
        for row in split(into: rows) {
            let natural = width(of: row) * scale
            // Squeezed only past the smallest scale, when the row can't fit across otherwise.
            let squeeze = natural > bounds.width && row.count > 1 ? (bounds.width - room.width) / (natural - room.width) : 1
            var x = bounds.minX + (bounds.width - min(natural, bounds.width)) / 2
            for index in row {
                places[reading[index].id] = CGRect(x: x.rounded(), y: y.rounded(), width: room.width, height: room.height)
                x += (room.width + after[index] * scale) * squeeze
            }
            y += room.height + rowGap * scale
        }
        return (scale, places)
    }

    /// `order` with `pile` moved to where `target` is, the piles between shifting along one. The
    /// Settled tray stays last.
    public static func moving(_ pile: Pile.ID, to target: Pile.ID, in order: [Pile.ID]) -> [Pile.ID] {
        guard pile != target, pile != .settled, order.contains(pile), let index = order.firstIndex(of: target) else { return order }
        var order = order
        order.removeAll { $0 == pile }
        let end = order.firstIndex(of: .settled) ?? order.endIndex
        order.insert(pile, at: min(index, end))
        return order
    }

    // MARK: At rest

    /// The pile in its place: an untidy stack, the top card square, the few behind it knocked a
    /// little out from under it and turned one way then the other, and its label below.
    private mutating func placeAtRest(_ pile: Pile, in slot: CGRect, front: TileItem?) {
        let card = CGSize(width: PileMetrics.card.width * scale, height: PileMetrics.card.height * scale)
        let origin = CGPoint(x: (slot.minX + PileMetrics.bleed.width * scale).rounded(), y: (slot.minY + PileMetrics.bleed.height * scale).rounded())
        var order = pile.cards
        if let front, let turn = order.firstIndex(of: front), turn > 0 {
            order = Array(order[turn...] + order[..<turn])
        }
        for (depth, item) in order.enumerated() {
            let (offset, rotation) = Self.untidy(item, depth: depth)
            cards.append(Card(
                item: item, pile: pile.id, depth: depth,
                frame: CGRect(x: origin.x + offset.x * scale, y: origin.y + offset.y * scale, width: card.width, height: card.height),
                rotation: rotation,
                z: -Double(depth),
                role: depth == 0 ? .top : .behind,
                rank: pile.rank(of: item)
            ))
        }
        let footprint = PileMetrics.footprint.height * scale
        labels.append(Label(
            pile: pile.id, projectID: pile.projectID, branch: pile.branch,
            frame: CGRect(x: slot.minX, y: (slot.minY + footprint).rounded(), width: slot.width, height: PileMetrics.labelHeight),
            isShown: true, z: 1
        ))
    }

    /// Where a card sits in its pile at rest, from its id: the top square, the next few knocked out
    /// a few points any way and turned one way then the other, so edges show on different sides;
    /// deeper ones square under the top, out of sight.
    static func untidy(_ item: TileItem, depth: Int) -> (offset: CGPoint, rotation: Double) {
        guard depth > 0, depth <= PileMetrics.maxVisibleBehind else { return (.zero, 0) }
        let seed = Seed(item)
        let shift = PileMetrics.behindOffset
        func knock(_ unit: Double) -> Double {
            (unit < 0 ? -1 : 1) * (shift.lowerBound + abs(unit) * (shift.upperBound - shift.lowerBound))
        }
        let turn = PileMetrics.behindRotation
        let side: Double = depth.isMultiple(of: 2) ? 1 : -1
        let rotation = side * (turn.lowerBound + abs(seed.unit(6)) * (turn.upperBound - turn.lowerBound))
        return (CGPoint(x: knock(seed.unit(4)), y: knock(seed.unit(5))), rotation)
    }

    /// The upright box a frame takes once turned about its centre.
    public static func turnedBounds(of frame: CGRect, by degrees: Double) -> CGRect {
        guard degrees != 0 else { return frame }
        let radians = abs(degrees) * .pi / 180
        let width = frame.width * cos(radians) + frame.height * sin(radians)
        let height = frame.width * sin(radians) + frame.height * cos(radians)
        return CGRect(x: frame.midX - width / 2, y: frame.midY - height / 2, width: width, height: height)
    }

    // MARK: Fanning a pile

    /// The pile's cards in full, in its own order, in a row where the pile sits (wrapping into more
    /// rows when it's wider than the screen), kept on screen. Its label hides meanwhile.
    private mutating func fanPile(_ pile: Pile, in bounds: CGRect, takesTargets: Bool = true) {
        guard let top = cards.first(where: { $0.pile == pile.id && $0.depth == 0 }) else { return }
        // Never smaller than the pile looked at rest, so a spread never shrinks its cards.
        let spread = Self.pileSpread(count: pile.cards.count, around: CGPoint(x: top.frame.midX, y: top.frame.midY), in: bounds, cardScale: max(1, scale))
        for (index, item) in pile.cards.enumerated() {
            guard let at = cards.firstIndex(where: { $0.item == item }) else { continue }
            cards[at].frame = spread[index].frame
            cards[at].rotation = spread[index].rotation
            cards[at].depth = index
            cards[at].z = 300_000 - Double(index)
            cards[at].role = .fanned
        }
        if let label = labels.firstIndex(where: { $0.pile == pile.id }) { labels[label].isShown = false }
        if takesTargets { targets = pile.cards }
    }

    /// A spread pile's cards, upright: up to `ringLimit` bloom round where the pile sits, the top
    /// card in the middle and the rest in a shape round it (a row, a plus, an asterisk); more sit in rows, each knocked a few points off true so it reads as dealt
    /// rather than ruled. The whole spread moves to stay inside `bounds`, and shrinks only if it can't.
    public static func pileSpread(count: Int, around centre: CGPoint, in bounds: CGRect, cardScale: Double = 1) -> [(frame: CGRect, rotation: Double)] {
        guard count > 0 else { return [] }
        guard count <= PileMetrics.ringLimit else {
            return pileFan(count: count, around: centre, in: bounds, cardScale: cardScale).enumerated().map { index, frame in
                // Stable per position, from a hash of its index, so a spread looks the same each time.
                func jitter(_ salt: Double) -> Double {
                    let x = sin(Double(index) * 12.9898 + salt * 78.233) * 43_758.5453
                    return (x - x.rounded(.down)) * 2 - 1
                }
                return (frame.offsetBy(dx: (jitter(1) * 5).rounded(), dy: (jitter(2) * 5).rounded()), 0)
            }
        }
        let full = CGSize(width: PileMetrics.card.width * cardScale, height: PileMetrics.card.height * cardScale)
        let gap = PileMetrics.fanGap * cardScale
        // A shape round the top card, in steps of a card and a gap: three in a row, five a plus,
        // seven an asterisk (its diagonal arms pushed out a little so they radiate). An even count
        // is the next shape with an arm left off.
        let step = CGSize(width: full.width + gap, height: full.height + gap)
        let arms: [(Double, Double)] = switch count {
        case 1: []
        case 2: [(1, 0)]
        case 3: [(-1, 0), (1, 0)]
        case 4: [(-1, 0), (1, 0), (0, -1)]
        case 5: [(-1, 0), (1, 0), (0, -1), (0, 1)]
        case 6: [(0, -1.3), (-1.15, -0.75), (1.15, -0.75), (-1.15, 0.75), (1.15, 0.75)]
        default: [(0, -1.3), (-1.15, -0.75), (1.15, -0.75), (-1.15, 0.75), (1.15, 0.75), (0, 1.3)]
        }
        let offsets = [CGPoint.zero] + arms.map { CGPoint(x: $0.0 * step.width, y: $0.1 * step.height) }
        let span = offsets.reduce(CGRect.null) { $0.union(CGRect(x: $1.x - full.width / 2, y: $1.y - full.height / 2, width: full.width, height: full.height)) }
        let fit = min(1, bounds.width / span.width, bounds.height / span.height)
        // No room for the shape at a readable size: rows instead.
        guard fit >= 0.8 else { return pileFan(count: count, around: centre, in: bounds, cardScale: cardScale).map { ($0, 0) } }
        let size = CGSize(width: full.width * fit, height: full.height * fit)
        let x = min(max(centre.x + span.minX * fit, bounds.minX), bounds.maxX - span.width * fit) - span.minX * fit
        let y = min(max(centre.y + span.minY * fit, bounds.minY), bounds.maxY - span.height * fit) - span.minY * fit
        return offsets.map { offset in
            (CGRect(x: (x + offset.x * fit - size.width / 2).rounded(), y: (y + offset.y * fit - size.height / 2).rounded(), width: size.width, height: size.height), 0)
        }
    }

    /// `count` full cards in rows centred on `centre`, as many to a row as the screen takes, moved
    /// to stay inside `bounds` and shrunk only if they can't.
    public static func pileFan(count: Int, around centre: CGPoint, in bounds: CGRect, cardScale: Double = 1) -> [CGRect] {
        guard count > 0 else { return [] }
        let gap = PileMetrics.fanGap * cardScale
        let full = CGSize(width: PileMetrics.card.width * cardScale, height: PileMetrics.card.height * cardScale)
        // The columns that give the biggest cards, the most of them when several do, the cards and
        // gaps shrinking together to fit.
        func fit(_ columns: Int) -> Double {
            let rows = Double((count + columns - 1) / columns)
            let width = Double(columns) * full.width + Double(columns - 1) * gap
            let height = rows * full.height + (rows - 1) * gap
            return min(1, bounds.width / width, bounds.height / height)
        }
        let columns = (1...count).max { (fit($0), $0) < (fit($1), $1) } ?? 1
        let rows = (count + columns - 1) / columns
        let fit = fit(columns)
        let size = CGSize(width: full.width * fit, height: full.height * fit)
        // The gaps shrink with the cards, or a shrunk spread still runs off the screen.
        let space = gap * fit
        let total = CGSize(width: Double(columns) * (size.width + space) - space, height: Double(rows) * (size.height + space) - space)
        let x = min(max(centre.x - total.width / 2, bounds.minX), bounds.maxX - total.width)
        let y = min(max(centre.y - total.height / 2, bounds.minY), bounds.maxY - total.height)
        return (0..<count).map { index in
            let (row, column) = index.quotientAndRemainder(dividingBy: columns)
            let inRow = row == rows - 1 ? count - row * columns : columns
            let indent = Double(columns - inRow) * (size.width + space) / 2
            return CGRect(x: (x + indent + Double(column) * (size.width + space)).rounded(), y: (y + Double(row) * (size.height + space)).rounded(), width: size.width, height: size.height)
        }
    }

    // MARK: Dragging

    /// The dragged pile, label and all, or the dragged card, moved with the pointer above everything.
    private mutating func apply(_ drag: PileDrag) {
        for index in cards.indices {
            let follows = switch drag.subject {
            case .pile(let id): cards[index].pile == id
            case .card(let item): cards[index].item == item
            }
            guard follows else { continue }
            cards[index].frame = cards[index].frame.offsetBy(dx: drag.offset.dx, dy: drag.offset.dy)
            cards[index].z += 400_000
        }
        if case .pile(let id) = drag.subject, let label = labels.firstIndex(where: { $0.pile == id }) {
            labels[label].frame = labels[label].frame.offsetBy(dx: drag.offset.dx, dy: drag.offset.dy)
            labels[label].z += 400_000
        }
    }

    /// Grid: where a pile dragged `offset` from its slot lands: the slot nearest its middle.
    public func dropSlot(of pile: Pile.ID, by offset: CGVector) -> PileSlot? {
        guard let grid, let slot = slots[pile] else { return nil }
        let frame = grid.frame(of: slot)
        return grid.nearest(to: CGPoint(x: frame.midX + offset.dx, y: frame.midY + offset.dy))
    }

    /// Exposé: the pile whose place a pile dragged `offset` from its own lands on: the one whose
    /// middle is nearest the dragged pile's.
    public func dropTarget(of pile: Pile.ID, by offset: CGVector) -> Pile.ID? {
        guard grid == nil, let place = places[pile] else { return nil }
        let middle = CGPoint(x: place.midX + offset.dx, y: place.midY + offset.dy)
        // In order, so ties go to the first.
        return order.filter { places[$0] != nil }.min { a, b in
            hypot(places[a]!.midX - middle.x, places[a]!.midY - middle.y) < hypot(places[b]!.midX - middle.x, places[b]!.midY - middle.y)
        }
    }

    /// Where a card of a spread pile dragged `offset` lands: the place of the card in its pile whose
    /// middle is nearest the dragged card's, as an index into the pile's cards. Asked of the layout
    /// with the drag applied.
    public func dropIndex(of item: TileItem, by offset: CGVector) -> Int? {
        guard let card = cards.first(where: { $0.item == item }), card.role == .fanned else { return nil }
        let centre = CGPoint(x: card.frame.midX, y: card.frame.midY)
        let spread = cards.filter { $0.pile == card.pile && $0.role == .fanned }
        func distance(_ other: Card) -> Double {
            // From where the dragged card started, so its own place is measured with the rest.
            let middle = other.item == item ? CGPoint(x: centre.x - offset.dx, y: centre.y - offset.dy) : CGPoint(x: other.frame.midX, y: other.frame.midY)
            return hypot(middle.x - centre.x, middle.y - centre.y)
        }
        return spread.min { distance($0) < distance($1) }?.depth
    }
}

/// Stable values in -1...1 from an id's bytes (not `hashValue`, which changes every launch).
struct Seed {
    private let bytes: [UInt8]

    init(_ item: TileItem) {
        let id = switch item { case .session(let id), .terminal(let id): id }
        bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
    }

    func unit(_ index: Int) -> Double {
        let value = UInt16(bytes[(2 * index) % 16]) << 8 | UInt16(bytes[(2 * index + 1) % 16])
        return Double(value) / Double(UInt16.max) * 2 - 1
    }
}
