import Foundation

/// A JSON-RPC error returned by Codex, or one we send back for requests we don't handle.
struct CodexRPCError: Error, Hashable, Codable {
    var code: Int
    var message: String
}

/// A notification or server request that belongs to one Codex thread.
struct CodexServerMessage: Sendable {
    var method: String
    var params: CodexJSON
    /// Set when Codex expects a response.
    var requestID: CodexRequestID?

    var threadID: String? { params["threadId"]?.stringValue }
}

enum CodexThreadEvent: Sendable {
    case message(CodexServerMessage)
    /// The app-server went away. Every thread on it is over.
    case serverClosed(exitCode: Int32?)
}

/// A JSON-RPC client for one `codex app-server`, shared by every Codex session.
/// It matches responses to request ids and routes notifications and server requests by thread id.
actor CodexAppServer {
    /// Server requests a session answers. Anything else is rejected so Codex doesn't wait on it.
    static let routedRequests: Set<String> = [
        CodexMethod.commandApproval, CodexMethod.fileChangeApproval,
        CodexMethod.permissionsApproval, CodexMethod.requestUserInput,
    ]

    private static let bufferLimit = 2_000

    private let transport: any CodexTransport
    private let outgoing: AsyncStream<Data>.Continuation
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<CodexJSON, any Error>] = [:]
    private var threads: [String: AsyncStream<CodexThreadEvent>.Continuation] = [:]
    /// Messages for threads nobody has subscribed to yet, such as those that race a `thread/start` response.
    private var unrouted: [String: [CodexServerMessage]] = [:]
    private var closedThreads: Set<String> = []
    private var tasks: [Task<Void, Never>] = []
    private(set) var isClosed = false

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return encoder
    }()

    init(transport: any CodexTransport) {
        self.transport = transport
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        self.outgoing = continuation
        tasks.append(Task { [transport] in
            for await line in stream {
                do { try await transport.send(line) } catch { break }
            }
        })
    }

    /// Starts reading and performs the `initialize` / `initialized` handshake.
    func start() async throws {
        tasks.append(Task { [transport] in
            for await line in transport.lines {
                self.receive(line)
            }
            await self.transportEnded()
        })
        let params = CodexInitializeParams(
            clientInfo: .init(name: "constellation", title: "Constellation", version: "1.0"),
            capabilities: .init(experimentalApi: true)
        )
        _ = try await request(CodexMethod.initialize, params, as: CodexJSON.self)
        try notify(CodexMethod.initialized)
    }

    func request<Response: Decodable>(_ method: String, _ params: some Encodable, as _: Response.Type = Response.self) async throws -> Response {
        guard !isClosed else { throw ProviderError.processExited(code: -1) }
        let id = nextID
        nextID += 1
        let line = try encoder.encode(OutgoingRequest(id: id, method: method, params: params))
        let result = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            outgoing.yield(line)
        }
        return try result.decode(Response.self)
    }

    func notify(_ method: String) throws {
        outgoing.yield(try encoder.encode(OutgoingNotification(method: method)))
    }

    func respond(to id: CodexRequestID, result: some Encodable) throws {
        outgoing.yield(try encoder.encode(OutgoingResponse(id: id, result: result)))
    }

    func reject(_ id: CodexRequestID, code: Int = -32601, message: String) {
        if let line = try? encoder.encode(OutgoingError(id: id, error: CodexRPCError(code: code, message: message))) {
            outgoing.yield(line)
        }
    }

    /// Everything Codex sends about one thread, including messages that arrived before this call.
    func subscribe(threadID: String) -> AsyncStream<CodexThreadEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: CodexThreadEvent.self)
        closedThreads.remove(threadID)
        if isClosed {
            continuation.yield(.serverClosed(exitCode: nil))
            continuation.finish()
            return stream
        }
        for message in unrouted.removeValue(forKey: threadID) ?? [] {
            continuation.yield(.message(message))
        }
        threads[threadID] = continuation
        return stream
    }

    func unsubscribe(threadID: String) {
        threads.removeValue(forKey: threadID)?.finish()
        unrouted[threadID] = nil
        closedThreads.insert(threadID)
    }

    func close() async {
        guard !isClosed else { return }
        outgoing.finish()
        _ = await transport.close()
    }

    // MARK: Receiving

    private func receive(_ line: Data) {
        guard let frame = try? JSONDecoder().decode(IncomingFrame.self, from: line) else { return }
        switch (frame.id, frame.method) {
        case (let id?, nil):
            guard case .int(let key) = id, let continuation = pending.removeValue(forKey: key) else { return }
            if let error = frame.error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: frame.result ?? .null)
            }
        case (let id?, let method?):
            let message = CodexServerMessage(method: method, params: frame.params ?? .null, requestID: id)
            guard Self.routedRequests.contains(method), let threadID = message.threadID else {
                reject(id, message: "Constellation does not handle \(method)")
                return
            }
            route(message, to: threadID)
        case (nil, let method?):
            let message = CodexServerMessage(method: method, params: frame.params ?? .null)
            if let threadID = message.threadID { route(message, to: threadID) }
        case (nil, nil):
            return
        }
    }

    private func route(_ message: CodexServerMessage, to threadID: String) {
        if let continuation = threads[threadID] {
            continuation.yield(.message(message))
        } else if !closedThreads.contains(threadID) {
            var buffered = unrouted[threadID, default: []]
            if buffered.count < Self.bufferLimit { buffered.append(message) }
            unrouted[threadID] = buffered
        } else if let id = message.requestID {
            reject(id, code: -32603, message: "The Constellation session for this thread has stopped")
        }
    }

    private func transportEnded() async {
        isClosed = true
        outgoing.finish()
        let code = await transport.close()
        for continuation in pending.values {
            continuation.resume(throwing: ProviderError.processExited(code: code ?? -1))
        }
        pending.removeAll()
        for continuation in threads.values {
            continuation.yield(.serverClosed(exitCode: code))
            continuation.finish()
        }
        threads.removeAll()
        unrouted.removeAll()
    }
}

private struct IncomingFrame: Decodable {
    var id: CodexRequestID?
    var method: String?
    var params: CodexJSON?
    var result: CodexJSON?
    var error: CodexRPCError?
}

private struct OutgoingRequest<Params: Encodable>: Encodable {
    var id: Int
    var method: String
    var params: Params
}

private struct OutgoingNotification: Encodable {
    var method: String
}

private struct OutgoingResponse<Result: Encodable>: Encodable {
    var id: CodexRequestID
    var result: Result
}

private struct OutgoingError: Encodable {
    var id: CodexRequestID
    var error: CodexRPCError
}
