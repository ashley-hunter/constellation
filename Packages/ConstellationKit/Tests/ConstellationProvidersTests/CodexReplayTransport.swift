import Foundation
import Testing
@testable import ConstellationProviders

/// Plays back a capture from a real `codex app-server` session. Each time the client sends a frame,
/// it consumes the matching recorded outgoing frame and emits the recorded incoming frames up to the next one.
/// Request ids are remapped so responses follow the client's own numbering.
actor CodexReplayTransport: CodexTransport {
    private struct Frame {
        var outgoing: Bool
        var json: CodexJSON
    }

    nonisolated let lines: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private var frames: [Frame]
    private var index = 0
    private var recordedToActual: [CodexRequestID: CodexRequestID] = [:]
    private(set) var sent: [CodexJSON] = []

    init(fixture name: String) throws {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/Codex/\(name).jsonl")
        let text = try String(contentsOf: url, encoding: .utf8)
        frames = try text.split(separator: "\n").map { line in
            let entry = try JSONDecoder().decode(CodexJSON.self, from: Data(line.utf8))
            return Frame(outgoing: entry["dir"]?.stringValue == "out", json: entry["frame"] ?? .null)
        }
        (lines, continuation) = AsyncStream.makeStream(of: Data.self)
    }

    func send(_ line: Data) throws {
        let frame = try JSONDecoder().decode(CodexJSON.self, from: line)
        sent.append(frame)
        guard index < frames.count else {
            answerPastTheEnd(frame)
            return
        }
        let recorded = frames[index]
        #expect(recorded.outgoing, "client sent \(frame["method"]?.stringValue ?? "a response") where the capture expected the server to speak")
        #expect(recorded.json["method"] == frame["method"], "client sent \(String(describing: frame["method"])), capture has \(String(describing: recorded.json["method"]))")
        if frame["method"] != nil, let actual = frame["id"], let original = recorded.json["id"] {
            recordedToActual[try original.decode(CodexRequestID.self)] = try actual.decode(CodexRequestID.self)
        }
        index += 1
        flush()
    }

    func close() -> Int32? {
        continuation.finish()
        return 0
    }

    /// Requests and notifications the client has sent, by method.
    func sentMethods() -> [String] {
        sent.compactMap { $0["method"]?.stringValue }
    }

    /// The nth response the client sent to a server request. Responses are written asynchronously,
    /// so this waits briefly for it to arrive.
    func response(at position: Int) async -> CodexJSON? {
        for _ in 0..<200 {
            let responses = sent.filter { $0["method"] == nil }
            if responses.count > position { return responses[position] }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    /// Requests sent after the capture ends get a stand-in response so callers don't wait forever.
    private func answerPastTheEnd(_ frame: CodexJSON) {
        guard frame["method"] != nil, let id = frame["id"] else { return }
        let turn = CodexJSON.object(["id": .string("replay-turn"), "status": .string("inProgress")])
        let response = CodexJSON.object(["id": id, "result": .object(["turn": turn])])
        if let data = try? JSONEncoder().encode(response) { continuation.yield(data) }
    }

    private func flush() {
        while index < frames.count, !frames[index].outgoing {
            var json = frames[index].json
            if json["method"] == nil, let id = json["id"], let original = try? id.decode(CodexRequestID.self),
               let actual = recordedToActual[original], case .object(var object) = json {
                object["id"] = try? CodexJSON(encoding: actual)
                json = .object(object)
            }
            if let data = try? JSONEncoder().encode(json) { continuation.yield(data) }
            index += 1
        }
    }
}
