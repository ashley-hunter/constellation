import Foundation

// The desktop's old arrangements, dragged positions and pinned groups. Only the store still reads
// and writes them, so the rows already saved keep their shape; the desktop no longer uses them.

public enum Arrangement: String, CaseIterable, Hashable, Codable, Sendable {
    case projects
    case related
    case attention
}

/// A tile position saved by dragging, in desktop points.
public struct TilePosition: Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct RelatedGroup: Identifiable, Hashable, Codable, Sendable {
    public enum Origin: Hashable, Codable, Sendable {
        case inferred(RelatedReason)
        /// Pinned by dragging one tile onto another, named by you.
        case pinned(name: String)
    }

    public var id: UUID
    public var origin: Origin
    public var members: Set<TileItem>

    public init(id: UUID = UUID(), origin: Origin, members: Set<TileItem>) {
        self.id = id
        self.origin = origin
        self.members = members
    }
}

public enum RelatedReason: Hashable, Codable, Sendable {
    case overlappingFiles([String])
    case sharedBaseBranch(String)
    case samePullRequest(Int)
}
