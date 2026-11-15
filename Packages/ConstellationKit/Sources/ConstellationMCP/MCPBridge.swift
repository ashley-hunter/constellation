import ConstellationCore
import Foundation

/// The app side of the Constellation MCP server: a Unix domain socket that each session's
/// `constellation-mcp` process connects to. Every message names its session, so one socket
/// serves all sessions and the app routes `requests` by `sessionID`.
public actor MCPBridge {
    public static let sessionIDEnvironmentKey = "CONSTELLATION_SESSION_ID"
    public static let socketEnvironmentKey = "CONSTELLATION_MCP_SOCKET"

    /// `$TMPDIR/constellation-<uid>/mcp.sock`.
    public static var defaultSocketURL: URL {
        FileManager.default.temporaryDirectory
            .appending(path: "constellation-\(getuid())")
            .appending(path: "mcp.sock")
    }

    public nonisolated let socketURL: URL
    public nonisolated let requests: AsyncStream<MCPBridgeRequest>
    private let continuation: AsyncStream<MCPBridgeRequest>.Continuation

    private var listener: DispatchSourceRead?
    private var connections: [UUID: Connection] = [:]
    /// Which connection is waiting on each `request_secret`.
    private var pendingSecrets: [UUID: UUID] = [:]

    public init(socketURL: URL = MCPBridge.defaultSocketURL) {
        self.socketURL = socketURL
        (requests, continuation) = AsyncStream.makeStream()
    }

    public func start() throws {
        guard listener == nil else { return }
        let directory = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let fd = try UnixSocket.listen(at: socketURL.path(percentEncoded: false))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "MCPBridge.accept"))
        source.setEventHandler { [weak self] in
            while case let client = accept(fd, nil, nil), client >= 0 {
                var on: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                Task { await self?.attach(client) }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        listener = source
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.close() }
        connections = [:]
        withdrawPendingSecrets { _ in true }
        unlink(socketURL.path(percentEncoded: false))
    }

    /// Answers a pending `request_secret` call. A nil value is a denial.
    public func respond(toSecretRequest requestID: UUID, value: String?) {
        guard let connectionID = pendingSecrets.removeValue(forKey: requestID) else { return }
        connections[connectionID]?.send(.secretResponse(id: requestID, value: value))
    }

    /// The MCP server entry handed to providers for one session.
    public nonisolated func serverConfig(for sessionID: UUID, helper: URL) -> MCPServerConfig {
        MCPServerConfig(
            command: helper,
            environment: [
                Self.sessionIDEnvironmentKey: sessionID.uuidString,
                Self.socketEnvironmentKey: socketURL.path(percentEncoded: false),
            ]
        )
    }

    private func attach(_ fd: Int32) {
        let id = UUID()
        let connection = Connection(fd: fd)
        connections[id] = connection
        Task {
            for await line in LineReader.lines(from: fd) {
                guard let message = try? JSONDecoder().decode(MCPSocketMessage.self, from: line) else { continue }
                self.receive(message, from: id)
            }
            self.detach(id)
        }
    }

    private func receive(_ message: MCPSocketMessage, from connectionID: UUID) {
        switch message {
        case let .requestSecret(id, sessionID, name, reason):
            pendingSecrets[id] = connectionID
            continuation.yield(.requestSecret(id: id, sessionID: sessionID, name: name, reason: reason))
        case let .cancelSecretRequest(id):
            guard pendingSecrets[id] == connectionID else { return }
            pendingSecrets[id] = nil
            continuation.yield(.secretRequestWithdrawn(id: id))
        case let .reportOutcome(sessionID, outcome):
            continuation.yield(.reportOutcome(sessionID: sessionID, outcome))
        case .secretResponse:
            break
        }
    }

    private func detach(_ connectionID: UUID) {
        connections.removeValue(forKey: connectionID)?.close()
        withdrawPendingSecrets { $0 == connectionID }
    }

    private func withdrawPendingSecrets(where matches: (UUID) -> Bool) {
        for (requestID, connectionID) in pendingSecrets where matches(connectionID) {
            pendingSecrets[requestID] = nil
            continuation.yield(.secretRequestWithdrawn(id: requestID))
        }
    }
}

private final class Connection: Sendable {
    let handle: FileHandle

    init(fd: Int32) {
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    func send(_ message: MCPSocketMessage) {
        guard var data = try? JSONEncoder().encode(message) else { return }
        data.append(UInt8(ascii: "\n"))
        try? UnixSocket.write(data, to: handle.fileDescriptor)
    }

    func close() {
        shutdown(handle.fileDescriptor, SHUT_RDWR)
    }
}

public enum MCPBridgeRequest: Hashable, Sendable {
    case requestSecret(id: UUID, sessionID: UUID, name: String, reason: String)
    /// The agent cancelled the call or its `constellation-mcp` exited before the app answered.
    case secretRequestWithdrawn(id: UUID)
    case reportOutcome(sessionID: UUID, Outcome)
}

/// Newline-delimited JSON exchanged between `constellation-mcp` and the bridge.
public enum MCPSocketMessage: Hashable, Codable, Sendable {
    case requestSecret(id: UUID, sessionID: UUID, name: String, reason: String)
    case cancelSecretRequest(id: UUID)
    case secretResponse(id: UUID, value: String?)
    case reportOutcome(sessionID: UUID, Outcome)
}
