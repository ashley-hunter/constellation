import ConstellationCore
import ConstellationMCP
import Foundation

/// Relays tool calls to the app's `MCPBridge`. Connects on first use and reconnects after the app restarts.
actor BridgeClient: MCPToolBackend {
    struct Unavailable: Error, CustomStringConvertible {
        var description: String
    }

    private let socketPath: String
    private let sessionID: UUID?
    private var connection: FileHandle?
    private var waiting: [UUID: CheckedContinuation<String?, any Error>] = [:]

    init(socketPath: String, sessionID: UUID?) {
        self.socketPath = socketPath
        self.sessionID = sessionID
    }

    func requestSecret(name: String, reason: String) async throws -> String? {
        let sessionID = try requireSessionID()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    waiting[id] = continuation
                    try send(.requestSecret(id: id, sessionID: sessionID, name: name, reason: reason))
                } catch {
                    waiting[id]?.resume(throwing: error)
                    waiting[id] = nil
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func reportOutcome(_ outcome: Outcome) async throws {
        try send(.reportOutcome(sessionID: try requireSessionID(), outcome))
    }

    private func requireSessionID() throws -> UUID {
        guard let sessionID else { throw Unavailable(description: "\(MCPBridge.sessionIDEnvironmentKey) is not set") }
        return sessionID
    }

    private func cancel(_ id: UUID) {
        guard let continuation = waiting.removeValue(forKey: id) else { return }
        continuation.resume(throwing: CancellationError())
        try? send(.cancelSecretRequest(id: id))
    }

    private func send(_ message: MCPSocketMessage) throws {
        var data = try JSONEncoder().encode(message)
        data.append(UInt8(ascii: "\n"))
        let handle = try connect()
        do {
            try UnixSocket.write(data, to: handle.fileDescriptor)
        } catch {
            disconnect(handle)
            throw Unavailable(description: "Constellation is not reachable (\(error))")
        }
    }

    private func connect() throws -> FileHandle {
        if let connection { return connection }
        let fd: Int32
        do {
            fd = try UnixSocket.connect(to: socketPath)
        } catch {
            throw Unavailable(description: "Constellation is not running or not reachable at \(socketPath) (\(error))")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        connection = handle
        Task { await read(handle) }
        return handle
    }

    private func read(_ handle: FileHandle) async {
        for await line in LineReader.lines(from: handle.fileDescriptor) {
            guard case let .secretResponse(id, value) = try? JSONDecoder().decode(MCPSocketMessage.self, from: line)
            else { continue }
            waiting.removeValue(forKey: id)?.resume(returning: value)
        }
        disconnect(handle)
    }

    private func disconnect(_ handle: FileHandle) {
        guard connection === handle else { return }
        connection = nil
        shutdown(handle.fileDescriptor, SHUT_RDWR)
        let pending = waiting.values
        waiting = [:]
        for continuation in pending {
            continuation.resume(throwing: Unavailable(description: "Constellation closed the connection"))
        }
    }
}
