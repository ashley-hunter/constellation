import Foundation

/// A file or image sent with a message. The bytes live in Constellation's attachment folder in
/// Application Support, so transcripts keep showing them after the worktree is cleaned up.
public struct Attachment: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: String, Hashable, Codable, Sendable {
        case image, pdf, file
    }

    public var id: UUID
    /// The original file name, or a generated one for pasted image data.
    public var name: String
    public var kind: Kind
    public var mimeType: String
    public var byteCount: Int
    /// Constellation's own copy.
    public var storedURL: URL
    /// Where the file came from, when it was a file and not pasted data.
    public var sourceURL: URL?
    /// Pages in a PDF, when they could be counted.
    public var pageCount: Int?

    public init(
        id: UUID = UUID(),
        name: String,
        kind: Kind,
        mimeType: String,
        byteCount: Int,
        storedURL: URL,
        sourceURL: URL? = nil,
        pageCount: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.storedURL = storedURL
        self.sourceURL = sourceURL
        self.pageCount = pageCount
    }

    /// Whether the provider takes the attachment's content directly. Everything else goes in the
    /// message as a path the agent can read.
    public func isInline(for provider: Provider) -> Bool {
        switch (kind, provider) {
        case (.image, _): true
        case (.pdf, .claudeCode):
            byteCount < AttachmentRules.maxInlinePDFBytes && (pageCount ?? .max) <= AttachmentRules.maxInlinePDFPages
        case (.pdf, .codex), (.file, _): false
        }
    }
}

public enum AttachmentRules {
    public static let maxImageBytes = 10 * 1_024 * 1_024
    public static let maxImagesPerMessage = 20
    /// Base64 adds a third, and the whole request must stay under the API's 32 MB, so larger PDFs
    /// go as a path instead.
    public static let maxInlinePDFBytes = 20 * 1_024 * 1_024
    public static let maxInlinePDFPages = 100
    /// Other files are copied into Application Support too, so very large ones are refused.
    public static let maxFileBytes = 200 * 1_024 * 1_024

    /// Image types the providers accept, by file extension.
    public static let imageTypes: [String: String] = [
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "gif": "image/gif",
        "webp": "image/webp",
    ]

    public static func kind(forExtension pathExtension: String) -> (Attachment.Kind, mimeType: String) {
        let ext = pathExtension.lowercased()
        if let mime = imageTypes[ext] { return (.image, mime) }
        if ext == "pdf" { return (.pdf, "application/pdf") }
        return (.file, "application/octet-stream")
    }

    /// Why an attachment can't join a message that already has `existing`, or nil when it can.
    public static func rejection(of attachment: Attachment, joining existing: [Attachment]) -> String? {
        switch attachment.kind {
        case .image:
            if attachment.byteCount > maxImageBytes { return "\(attachment.name) is over 10 MB" }
            if existing.count(where: { $0.kind == .image }) >= maxImagesPerMessage { return "A message can carry up to 20 images" }
        case .pdf, .file:
            if attachment.byteCount > maxFileBytes { return "\(attachment.name) is over 200 MB" }
        }
        return nil
    }
}

/// What you send to a session: your words and any attachments.
public struct UserMessage: Hashable, Codable, Sendable {
    public var text: String
    public var attachments: [Attachment]
    /// Where the agent can read each attachment sent as a path, by attachment id. Files from outside
    /// the worktree are copied into it first, so this is filled in just before sending.
    public var agentPaths: [UUID: String]

    public init(text: String, attachments: [Attachment] = [], agentPaths: [UUID: String] = [:]) {
        self.text = text
        self.attachments = attachments
        self.agentPaths = agentPaths
    }

    public var isEmpty: Bool {
        text.allSatisfy(\.isWhitespace) && attachments.isEmpty
    }

    /// The attachments a provider takes as content blocks or input items.
    public func inlineAttachments(for provider: Provider) -> [Attachment] {
        attachments.filter { $0.isInline(for: provider) }
    }

    /// The text to send: your words, then the paths of attachments the provider can't take inline.
    public func promptText(for provider: Provider) -> String {
        let paths = attachments.filter { !$0.isInline(for: provider) }.map { attachment in
            agentPaths[attachment.id] ?? attachment.sourceURL?.path(percentEncoded: false) ?? attachment.storedURL.path(percentEncoded: false)
        }
        guard !paths.isEmpty else { return text }
        let list = (paths.count == 1 ? "Attached file: " : "Attached files:\n") + paths.map { paths.count == 1 ? $0 : "- \($0)" }.joined(separator: "\n")
        return text.allSatisfy(\.isWhitespace) ? list : text + "\n\n" + list
    }
}
