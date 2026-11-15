import Darwin
import Foundation

/// The port a worktree's dev servers use, so two worktrees of one project can each run theirs. It
/// comes from the worktree's path, so it's the same every launch, moving on past any port already
/// listening when it's chosen.
public enum WorktreePort {
    public static let range = 4100...4999

    public static func port(for worktree: URL, isTaken: (Int) -> Bool = isListening) -> Int {
        var path = worktree.standardizedFileURL.path(percentEncoded: false)
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        // FNV-1a, since Swift's own hash changes from launch to launch.
        let hash = path.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        let start = Int(hash % UInt64(range.count))
        let candidates = (0..<range.count).map { range.lowerBound + (start + $0) % range.count }
        return candidates.first { !isTaken($0) } ?? candidates[0]
    }

    /// What a process in the worktree is given: `PORT` for the tools that read it, and
    /// `CONSTELLATION_PORT` for scripts that want it by name.
    public static func environment(_ port: Int) -> [String: String] {
        ["PORT": String(port), "CONSTELLATION_PORT": String(port)]
    }

    /// Something accepts connections on the port, over IPv4 or IPv6 loopback.
    public static func isListening(_ port: Int) -> Bool {
        accepts(family: AF_INET, port: port) || accepts(family: AF_INET6, port: port)
    }

    private static func accepts(family: Int32, port: Int) -> Bool {
        let socket = Darwin.socket(family, SOCK_STREAM, 0)
        guard socket >= 0 else { return false }
        defer { close(socket) }
        if family == AF_INET {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(UInt16(port).bigEndian)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            return withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
            }
        }
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = in_port_t(UInt16(port).bigEndian)
        address.sin6_addr = in6addr_loopback
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0 }
        }
    }
}
