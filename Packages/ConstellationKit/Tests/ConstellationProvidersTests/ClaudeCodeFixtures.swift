import ConstellationCore
import Foundation
@testable import ConstellationProviders

/// Sanitized frames captured from Claude Code 2.1.314 in a throwaway repo at `/tmp/fixture-repo`.
/// Each line is `{"dir": "in" | "out" | "exit", "frame": ...}`; `in` frames are what the host sent.
struct ClaudeCodeFixture {
    struct Entry {
        var direction: String
        var frame: JSONValue
    }

    static let directory = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Fixtures/claude-code")

    static let workingDirectory = URL(filePath: "/tmp/fixture-repo")
    static let sessionID = UUID(uuidString: "6F1D2C1E-0000-4000-8000-000000000001")!

    let name: String
    let entries: [Entry]

    init(_ name: String) throws {
        self.name = name
        let data = try Data(contentsOf: Self.directory.appending(path: "\(name).jsonl"))
        var buffer = LineBuffer()
        entries = try (buffer.append(data) + [buffer.flush()].compactMap { $0 }).map { line in
            let entry = try JSONValue.decode(line)
            return Entry(direction: entry["dir"]?.string ?? "", frame: entry["frame"] ?? .null)
        }
    }

    var outgoing: [JSONValue] { entries.filter { $0.direction == "in" }.map(\.frame) }

    /// The `session_id` the CLI reported, so replays can start from the id Constellation chose.
    var nativeID: String {
        entries.lazy.compactMap { $0.frame["session_id"]?.string }.first { !$0.isEmpty } ?? ""
    }

    /// The control_response the host sent for a given request id.
    func sentResponse(to requestID: String) -> JSONValue? {
        outgoing.first { $0["type"]?.string == "control_response" && $0["response"]?["request_id"]?.string == requestID }
    }

    func translator() -> ClaudeCodeTranslator {
        ClaudeCodeTranslator(
            sessionID: Self.sessionID,
            nativeID: nativeID,
            workingDirectory: Self.workingDirectory,
            now: { Date(timeIntervalSince1970: 0) }
        )
    }

    /// Replays the capture through a translator, mirroring the host's own messages and interrupts
    /// and the driver closing stdin at the end.
    func replay(into translator: inout ClaudeCodeTranslator) -> [SessionEvent] {
        var events: [SessionEvent] = []
        for entry in entries {
            switch entry.direction {
            case "out":
                events += translator.handle(entry.frame).events
            case "in" where entry.frame["request"]?["subtype"]?.string == "interrupt":
                translator.noteInterruptRequested()
            case "in" where entry.frame["type"]?.string == "user":
                translator.noteMessageSent()
            case "exit":
                let code = Int32(entry.frame.int ?? 0)
                events += translator.processExited(code: code, stopRequested: true, stderrTail: [])
            default:
                break
            }
        }
        return events
    }

    func replay() -> [SessionEvent] {
        var translator = translator()
        return replay(into: &translator)
    }
}

extension [SessionEvent] {
    var runStates: [String] {
        compactMap { event in
            switch event {
            case .runState(let state): state.rawValue
            case .interrupted: "interrupted"
            case .failed: "failed"
            default: nil
            }
        }
    }

    var asks: [Ask] {
        compactMap { if case .askRaised(let ask) = $0 { ask } else { nil } }
    }

    var toolCalls: [ToolCall] {
        compactMap { if case .toolCall(let call) = $0 { call } else { nil } }
    }

    var toolResults: [ToolResult] {
        compactMap { if case .toolResult(let result) = $0 { result } else { nil } }
    }

    var finalTexts: [String] {
        compactMap { if case .assistantText(let text, true) = $0 { text } else { nil } }
    }

    var failures: [(FailureReason, String)] {
        compactMap { if case .failed(let reason, let message) = $0 { (reason, message) } else { nil } }
    }
}
