import Foundation

/// Thin POSIX helpers for the bridge socket, shared by the app and `constellation-mcp`.
public enum UnixSocket {
    public struct Failure: Error, CustomStringConvertible {
        public let operation: String
        public let code: Int32

        public var description: String { "\(operation) failed: \(String(cString: strerror(code)))" }
    }

    public static let maxPathLength = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

    /// Binds a listening socket at `path`, replacing a stale socket file left by an earlier run.
    public static func listen(at path: String) throws -> Int32 {
        let fd = try makeSocket()
        unlink(path)
        do {
            try withAddress(path) { address, length in
                try check("bind", Darwin.bind(fd, address, length))
            }
            chmod(path, 0o600)
            try check("listen", Darwin.listen(fd, SOMAXCONN))
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    public static func connect(to path: String) throws -> Int32 {
        let fd = try makeSocket()
        do {
            try withAddress(path) { address, length in
                try check("connect", Darwin.connect(fd, address, length))
            }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    /// Writes all of `data`, retrying on short writes. Peers that hung up surface as EPIPE, not SIGPIPE.
    public static func write(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw Failure(operation: "write", code: errno)
                }
                offset += written
            }
        }
    }

    private static func makeSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        try check("socket", fd)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    static func check(_ operation: String, _ result: Int32) throws {
        if result < 0 { throw Failure(operation: operation, code: errno) }
    }

    private static func withAddress(
        _ path: String,
        _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> Void
    ) throws {
        let bytes = Array(path.utf8)
        guard bytes.count <= maxPathLength else { throw Failure(operation: "socket path", code: ENAMETOOLONG) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        address.sun_len = UInt8(length)
        try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0, length) }
        }
    }
}

/// Newline-delimited messages read from a file descriptor until EOF. Each reader gets its own dispatch
/// source: `FileHandle.bytes` runs every handle in the process through one blocking queue, so a stdin
/// read would starve the bridge socket. Splits on `\n` only, never on the U+2028 JSON leaves unescaped.
public enum LineReader {
    public static func lines(from fd: Int32) -> AsyncStream<Data> {
        AsyncStream { continuation in
            let buffer = LineBuffer()
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "LineReader"))
            source.setEventHandler {
                var chunk = [UInt8](repeating: 0, count: 64 * 1024)
                let count = read(fd, &chunk, chunk.count)
                if count > 0 {
                    for line in buffer.append(chunk[..<count]) { continuation.yield(line) }
                } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                    if !buffer.remainder.isEmpty { continuation.yield(buffer.remainder) }
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in source.cancel() }
            source.resume()
        }
    }
}

/// Only touched from its reader's serial dispatch queue.
private final class LineBuffer: @unchecked Sendable {
    private(set) var remainder = Data()

    func append(_ bytes: ArraySlice<UInt8>) -> [Data] {
        remainder.append(contentsOf: bytes)
        var lines: [Data] = []
        while let newline = remainder.firstIndex(of: UInt8(ascii: "\n")) {
            lines.append(Data(remainder[..<newline]))
            remainder = Data(remainder[(newline + 1)...])
        }
        return lines
    }
}
