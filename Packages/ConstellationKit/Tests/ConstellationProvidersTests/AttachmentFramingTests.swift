import ConstellationCore
import Foundation
import Testing
@testable import ConstellationProviders

@Suite struct AttachmentFramingTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "constellation-attach-\(UUID().uuidString)")

    private func stored(_ name: String, _ bytes: [UInt8], pages: Int? = nil) throws -> ConstellationCore.Attachment {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: name)
        try Data(bytes).write(to: url)
        let (kind, mime) = AttachmentRules.kind(forExtension: url.pathExtension)
        return ConstellationCore.Attachment(name: name, kind: kind, mimeType: mime, byteCount: bytes.count, storedURL: url, sourceURL: url, pageCount: pages)
    }

    @Test func claudeGetsImageAndDocumentBlocksBeforeTheText() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = try stored("dot.png", [0x89, 0x50, 0x4E, 0x47])
        let pdf = try stored("spec.pdf", [0x25, 0x50, 0x44, 0x46], pages: 2)
        let notes = try stored("notes.txt", [0x68, 0x69])
        let frame = try ClaudeCodeTranslator.userMessage(UserMessage(text: "What is this?", attachments: [image, pdf, notes]))

        let blocks = try #require(frame["message"]?["content"]?.array)
        #expect(blocks.map { $0["type"]?.string } == ["image", "document", "text"])
        #expect(blocks[0]["source"]?["type"]?.string == "base64")
        #expect(blocks[0]["source"]?["media_type"]?.string == "image/png")
        #expect(blocks[0]["source"]?["data"]?.string == Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString())
        #expect(blocks[1]["source"]?["media_type"]?.string == "application/pdf")
        #expect(blocks[2]["text"]?.string == "What is this?\n\nAttached file: \(notes.storedURL.path(percentEncoded: false))")
    }

    @Test func claudeKeepsPlainStringContentWithoutInlineAttachments() throws {
        let frame = try ClaudeCodeTranslator.userMessage(UserMessage(text: "hi"))
        #expect(frame == ClaudeCodeTranslator.userMessage("hi"))
    }

    @Test func claudeLeavesOutAnEmptyTextBlock() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = try stored("dot.png", [1, 2, 3])
        let frame = try ClaudeCodeTranslator.userMessage(UserMessage(text: "", attachments: [image]))
        #expect(frame["message"]?["content"]?.array?.map { $0["type"]?.string } == ["image"])
    }

    @Test func codexGetsLocalImagesAndPathsInTheText() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = try stored("dot.png", [1])
        let pdf = try stored("spec.pdf", [2], pages: 1)
        let items = CodexUserInput.items(for: UserMessage(text: "Look", attachments: [image, pdf]))
        let encoded = try JSONValue.decode(JSONEncoder().encode(items))
        #expect(encoded == [
            ["type": "localImage", "path": .string(image.storedURL.path(percentEncoded: false))],
            ["type": "text", "text": .string("Look\n\nAttached file: \(pdf.storedURL.path(percentEncoded: false))")],
        ])
    }
}
