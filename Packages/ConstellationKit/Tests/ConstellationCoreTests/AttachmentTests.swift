import Foundation
import Testing
@testable import ConstellationCore

private func attachment(_ name: String, bytes: Int = 1_000, pages: Int? = nil, source: String? = nil) -> ConstellationCore.Attachment {
    let (kind, mime) = AttachmentRules.kind(forExtension: (name as NSString).pathExtension)
    return ConstellationCore.Attachment(
        name: name, kind: kind, mimeType: mime, byteCount: bytes,
        storedURL: URL(filePath: "/support/attachments/\(name)"),
        sourceURL: source.map { URL(filePath: $0) }, pageCount: pages
    )
}

@Suite struct AttachmentTests {
    @Test func kindsComeFromTheExtension() {
        #expect(AttachmentRules.kind(forExtension: "PNG") == (.image, "image/png"))
        #expect(AttachmentRules.kind(forExtension: "jpg").mimeType == "image/jpeg")
        #expect(AttachmentRules.kind(forExtension: "webp").mimeType == "image/webp")
        #expect(AttachmentRules.kind(forExtension: "pdf").0 == .pdf)
        #expect(AttachmentRules.kind(forExtension: "heic").0 == .file)
    }

    @Test func imagesAreInlineForBothProviders() {
        let image = attachment("shot.png")
        #expect(image.isInline(for: .claudeCode))
        #expect(image.isInline(for: .codex))
    }

    @Test func pdfsAreInlineForClaudeOnlyWithinItsLimits() {
        #expect(attachment("spec.pdf", pages: 12).isInline(for: .claudeCode))
        #expect(!attachment("spec.pdf", pages: 12).isInline(for: .codex))
        #expect(!attachment("long.pdf", pages: 101).isInline(for: .claudeCode))
        #expect(!attachment("big.pdf", bytes: 24 * 1_024 * 1_024, pages: 3).isInline(for: .claudeCode))
        #expect(attachment("fits.pdf", bytes: 19 * 1_024 * 1_024, pages: 3).isInline(for: .claudeCode))
        #expect(!attachment("unknown.pdf").isInline(for: .claudeCode))
    }

    @Test func limitsRejectLargeImagesAndTooManyOfThem() {
        #expect(AttachmentRules.rejection(of: attachment("a.png", bytes: 11 * 1_024 * 1_024), joining: []) != nil)
        let twenty = (0..<20).map { attachment("\($0).png") }
        #expect(AttachmentRules.rejection(of: attachment("x.png"), joining: twenty) != nil)
        #expect(AttachmentRules.rejection(of: attachment("notes.txt"), joining: twenty) == nil)
        #expect(AttachmentRules.rejection(of: attachment("x.png"), joining: Array(twenty.dropFirst())) == nil)
    }

    @Test func filesGoInTheTextAsPaths() {
        let notes = attachment("notes.txt", source: "/Users/me/notes.txt")
        var message = UserMessage(text: "Read this", attachments: [attachment("a.png"), notes])
        #expect(message.promptText(for: .codex) == "Read this\n\nAttached file: /Users/me/notes.txt")
        message.agentPaths[notes.id] = "/wt/.constellation/attachments/notes.txt"
        #expect(message.promptText(for: .claudeCode) == "Read this\n\nAttached file: /wt/.constellation/attachments/notes.txt")
        #expect(message.inlineAttachments(for: .codex).map(\.name) == ["a.png"])
    }

    @Test func severalPathsAreListedAndATextlessMessageIsJustTheList() {
        let message = UserMessage(text: " ", attachments: [attachment("a.txt", source: "/a.txt"), attachment("b.pdf", source: "/b.pdf")])
        #expect(message.promptText(for: .codex) == "Attached files:\n- /a.txt\n- /b.pdf")
        #expect(UserMessage(text: "hi").promptText(for: .codex) == "hi")
        #expect(UserMessage(text: "  ").isEmpty)
        #expect(!message.isEmpty)
    }

    @Test func userMessagesStoredBeforeAttachmentsStillDecode() throws {
        let old = Data(#"{"userMessage":{"_0":"hello"}}"#.utf8)
        #expect(try JSONDecoder().decode(SessionEvent.self, from: old) == .userMessage("hello"))
        let event = SessionEvent.userMessage("look", attachments: [attachment("a.png")])
        #expect(try JSONDecoder().decode(SessionEvent.self, from: JSONEncoder().encode(event)) == event)
    }

    @Test func transcriptAndTileShowAttachments() {
        let event = SessionEvent.userMessage("look", attachments: [attachment("a.png"), attachment("b.png"), attachment("c.txt")])
        let transcript = Transcript([event])
        guard case .user(_, "look", let attachments)? = transcript.entries.first else {
            Issue.record("expected a user entry")
            return
        }
        #expect(attachments.count == 3)
        var output = LiveOutput()
        output.append(event)
        #expect(output.lines.last?.text == "› look [2 images, 1 file]")
    }
}
