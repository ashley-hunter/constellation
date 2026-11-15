import Foundation

/// Split screen: two to four sessions open side by side, each with its own transcript and reply
/// box, one of them holding the keys. Zoomed, the focused one fills the grid's space alone.
public struct SessionGrid: Hashable, Sendable {
    public static let capacity = 4

    public private(set) var ids: [UUID]
    public private(set) var focusedID: UUID
    public var isZoomed = false

    /// Nil unless there are two to four different sessions. Focus falls on the first unless named.
    public init?(_ ids: [UUID], focus: UUID? = nil) {
        guard (2...Self.capacity).contains(ids.count), Set(ids).count == ids.count, let first = ids.first else { return nil }
        self.ids = ids
        focusedID = focus.flatMap { ids.contains($0) ? $0 : nil } ?? first
    }

    public var isFull: Bool { ids.count >= Self.capacity }

    public func contains(_ id: UUID) -> Bool { ids.contains(id) }

    /// Adds a session as the last tile and focuses it. False when it's full or already there.
    @discardableResult
    public mutating func add(_ id: UUID) -> Bool {
        guard !isFull, !ids.contains(id) else { return false }
        ids.append(id)
        focusedID = id
        isZoomed = false
        return true
    }

    /// Takes a session out, focus passing to the tile before it. Returns the one session left when
    /// that leaves too few for a grid; the grid is unchanged then.
    public mutating func remove(_ id: UUID) -> UUID? {
        guard let index = ids.firstIndex(of: id) else { return nil }
        guard ids.count > 2 else { return ids.first { $0 != id } }
        ids.remove(at: index)
        if focusedID == id {
            focusedID = ids[max(index - 1, 0)]
            isZoomed = false
        }
        return nil
    }

    public mutating func focus(_ id: UUID) {
        guard ids.contains(id) else { return }
        focusedID = id
    }

    /// The tile beside the focused one in a direction, by where they sit in a grid of `count`.
    public func neighbour(_ step: Step) -> UUID? {
        guard let index = ids.firstIndex(of: focusedID) else { return nil }
        let frames = Self.frames(count: ids.count, in: CGRect(x: 0, y: 0, width: 1000, height: 1000), gap: 0)
        let from = frames[index]
        let candidates = frames.indices.filter { $0 != index && step.isAhead(frames[$0], of: from) }
        let nearest = candidates.min { step.distance(frames[$0], from) < step.distance(frames[$1], from) }
        return nearest.map { ids[$0] }
    }

    public enum Step: Sendable {
        case left, right, up, down

        fileprivate func isAhead(_ frame: CGRect, of from: CGRect) -> Bool {
            switch self {
            case .left: frame.maxX <= from.minX + 1
            case .right: frame.minX >= from.maxX - 1
            case .up: frame.maxY <= from.minY + 1 && frame.minX < from.maxX && frame.maxX > from.minX
            case .down: frame.minY >= from.maxY - 1 && frame.minX < from.maxX && frame.maxX > from.minX
            }
        }

        /// Straight across counts most, so ← from the bottom right of three lands on the tall left one.
        fileprivate func distance(_ frame: CGRect, _ from: CGRect) -> Double {
            abs(frame.midX - from.midX) + abs(frame.midY - from.midY)
        }
    }

    /// Where each of `count` tiles sits in `bounds`: two side by side, three as one tall on the
    /// left and two stacked on the right, four as two by two. Rounded to whole points.
    public static func frames(count: Int, in bounds: CGRect, gap: Double) -> [CGRect] {
        let halfWidth = ((bounds.width - gap) / 2).rounded(.down)
        let halfHeight = ((bounds.height - gap) / 2).rounded(.down)
        let rightX = bounds.maxX - halfWidth
        let lowerY = bounds.maxY - halfHeight
        let left = CGRect(x: bounds.minX, y: bounds.minY, width: halfWidth, height: bounds.height)
        let right = CGRect(x: rightX, y: bounds.minY, width: halfWidth, height: bounds.height)
        switch count {
        case ...0: return []
        case 1: return [bounds]
        case 2: return [left, right]
        case 3:
            return [
                left,
                CGRect(x: rightX, y: bounds.minY, width: halfWidth, height: halfHeight),
                CGRect(x: rightX, y: lowerY, width: halfWidth, height: halfHeight),
            ]
        default:
            return [
                CGRect(x: bounds.minX, y: bounds.minY, width: halfWidth, height: halfHeight),
                CGRect(x: rightX, y: bounds.minY, width: halfWidth, height: halfHeight),
                CGRect(x: bounds.minX, y: lowerY, width: halfWidth, height: halfHeight),
                CGRect(x: rightX, y: lowerY, width: halfWidth, height: halfHeight),
            ]
        }
    }
}
