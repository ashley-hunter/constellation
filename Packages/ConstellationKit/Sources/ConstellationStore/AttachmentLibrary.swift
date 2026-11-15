import ConstellationCore
import CoreGraphics
import Foundation

/// Constellation's own copies of attached files, in Application Support next to the store. Events
/// point at these, so a transcript keeps its images after the worktree is gone.
public struct AttachmentLibrary: Sendable {
    public enum ImportError: LocalizedError {
        case unreadable(String)
        case rejected(String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let name): "Couldn't read \(name)"
            case .rejected(let reason): reason
            }
        }
    }

    public static var defaultDirectory: URL {
        Store.defaultURL.deletingLastPathComponent().appending(path: "attachments", directoryHint: .isDirectory)
    }

    public let directory: URL

    public init(directory: URL = AttachmentLibrary.defaultDirectory) {
        self.directory = directory
    }

    /// Copies a file in, following a symlink to the file it names. Directories are refused.
    public func importFile(at url: URL) throws -> Attachment {
        let source = url.resolvingSymlinksInPath()
        let values = try? source.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        guard values?.isDirectory != true else { throw ImportError.rejected("\(url.lastPathComponent) is a folder") }
        guard let size = values?.fileSize else { throw ImportError.unreadable(url.lastPathComponent) }
        let (kind, mimeType) = AttachmentRules.kind(forExtension: url.pathExtension)
        try check(kind: kind, name: url.lastPathComponent, size: size)
        let id = UUID()
        let stored = storedURL(id: id, extension: url.pathExtension)
        try prepareDirectory()
        do {
            try FileManager.default.copyItem(at: source, to: stored)
        } catch {
            throw ImportError.unreadable(url.lastPathComponent)
        }
        return Attachment(
            id: id, name: url.lastPathComponent, kind: kind, mimeType: mimeType, byteCount: size,
            storedURL: stored, sourceURL: url, pageCount: kind == .pdf ? Self.pageCount(of: stored) : nil
        )
    }

    /// Deletes Constellation's copy of an attachment that was never sent.
    public func remove(_ attachment: Attachment) {
        guard attachment.storedURL.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: attachment.storedURL)
    }

    /// Writes pasted image data, e.g. a screenshot from the clipboard.
    public func importImage(_ data: Data, pathExtension: String) throws -> Attachment {
        let (kind, mimeType) = AttachmentRules.kind(forExtension: pathExtension)
        guard kind == .image else { throw ImportError.rejected("Only PNG, JPEG, GIF and WebP images can be pasted") }
        let id = UUID()
        let name = "Pasted image \(id.uuidString.prefix(4)).\(pathExtension.lowercased())"
        try check(kind: kind, name: name, size: data.count)
        let stored = storedURL(id: id, extension: pathExtension)
        try prepareDirectory()
        try data.write(to: stored, options: .atomic)
        return Attachment(id: id, name: name, kind: kind, mimeType: mimeType, byteCount: data.count, storedURL: stored)
    }

    private func check(kind: Attachment.Kind, name: String, size: Int) throws {
        let probe = Attachment(name: name, kind: kind, mimeType: "", byteCount: size, storedURL: directory)
        if let reason = AttachmentRules.rejection(of: probe, joining: []) { throw ImportError.rejected(reason) }
    }

    private func storedURL(id: UUID, extension pathExtension: String) -> URL {
        let name = pathExtension.isEmpty ? id.uuidString : "\(id.uuidString).\(pathExtension.lowercased())"
        return directory.appending(path: name)
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    static func pageCount(of pdf: URL) -> Int? {
        CGPDFDocument(pdf as CFURL)?.numberOfPages
    }
}
