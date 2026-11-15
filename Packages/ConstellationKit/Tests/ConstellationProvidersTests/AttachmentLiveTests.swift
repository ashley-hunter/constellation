import ConstellationCore
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ConstellationProviders

/// Sends a generated PNG to the real providers, then a queued follow-up once the turn ends, the way
/// the app's composer does. Opt in as for `ClaudeCodeLiveTests` and `CodexLiveTests`.
struct AttachmentLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CONSTELLATION_LIVE_CLAUDE"] == "1"), .timeLimit(.minutes(3)))
    func claudeDescribesAnImageThenRunsTheQueuedMessage() async throws {
        let repo = try LiveRepo()
        defer { repo.remove() }
        var launch = repo.launch(model: "haiku")
        launch.message = UserMessage(text: Self.question, attachments: [try repo.redSquare()])
        let handle = try await ClaudeCodeAdapter().start(launch)
        let texts = try await Self.run(handle, queued: [UserMessage(text: "Reply with exactly: queued-ok")])
        Self.check(texts)
    }

    @Test(.enabled(if: CodexLive.binary != nil), .timeLimit(.minutes(5)))
    func codexDescribesAnImageThenRunsTheQueuedMessage() async throws {
        let repo = try LiveRepo()
        defer { repo.remove() }
        let adapter = CodexAdapter(executable: CodexLive.binary)
        defer { Task { await adapter.shutdown() } }
        var launch = repo.launch(model: "")
        launch.message = UserMessage(text: Self.question, attachments: [try repo.redSquare()])
        let handle = try await adapter.start(launch)
        let texts = try await Self.run(handle, queued: [UserMessage(text: "Reply with exactly: queued-ok")])
        Self.check(texts)
    }

    static let question = "What single color fills the attached image? Answer with one lowercase word."

    /// Each turn's last assistant text. Queued messages go one per finished turn.
    static func run(_ handle: any ProviderSessionHandle, queued: [UserMessage]) async throws -> [String] {
        var queue = queued
        var texts: [String] = []
        var last = ""
        var state: RunState = .working
        for await event in handle.events {
            switch event {
            case .assistantText(let text, isFinal: true):
                last = text
            case .runState(.done):
                guard MessageQueue.shouldFlush(from: state, to: .done) else { continue }
                state = .done
                texts.append(last)
                if queue.isEmpty {
                    await handle.stop()
                } else {
                    state = .working
                    try await handle.send(queue.removeFirst())
                }
            case .failed(_, let message):
                Issue.record("turn failed: \(message)")
                await handle.stop()
            case .askRaised(let ask):
                Issue.record("unexpected ask: \(ask.kind.headline)")
                await handle.stop()
            default:
                break
            }
        }
        return texts
    }

    static func check(_ texts: [String]) {
        #expect(texts.count == 2, "\(texts)")
        #expect(texts.first?.lowercased().contains("red") == true, "\(texts)")
        #expect(texts.last?.contains("queued-ok") == true, "\(texts)")
    }
}

/// A throwaway git repo, with Constellation's attachment copy kept outside it as in the app.
struct LiveRepo {
    let root = FileManager.default.temporaryDirectory.appending(path: "constellation-live-\(UUID().uuidString)")
    var repo: URL { root.appending(path: "repo") }

    init() throws {
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let git = try Process.run(URL(filePath: "/usr/bin/git"), arguments: ["-C", repo.path(percentEncoded: false), "init", "-q"])
        git.waitUntilExit()
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func launch(model: String) -> SessionLaunch {
        SessionLaunch(
            sessionID: UUID(), workingDirectory: repo, model: model, permissionMode: .fullAuto, prompt: nil,
            mcpServer: MCPServerConfig(command: URL(filePath: "/usr/bin/true"))
        )
    }

    /// A 64×64 PNG filled with pure red.
    func redSquare() throws -> ConstellationCore.Attachment {
        let url = root.appending(path: "square.png")
        let context = try #require(CGContext(
            data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        let size = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.size] as? Int ?? 0
        return ConstellationCore.Attachment(name: "square.png", kind: .image, mimeType: "image/png", byteCount: size, storedURL: url)
    }
}
