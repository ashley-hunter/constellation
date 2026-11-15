import Foundation
import Testing
@testable import ConstellationStore

@Suite struct AttachmentLibraryTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "constellation-library-\(UUID().uuidString)")

    @Test func importsFilesAndPastedImages() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = AttachmentLibrary(directory: directory.appending(path: "attachments"))
        let source = directory.appending(path: "Shot.PNG")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: source)

        let file = try library.importFile(at: source)
        #expect(file.kind == .image)
        #expect(file.mimeType == "image/png")
        #expect(file.byteCount == 3)
        #expect(file.sourceURL == source)
        #expect(try Data(contentsOf: file.storedURL) == Data([1, 2, 3]))

        let pasted = try library.importImage(Data([4, 5]), pathExtension: "png")
        #expect(pasted.sourceURL == nil)
        #expect(try Data(contentsOf: pasted.storedURL) == Data([4, 5]))
        #expect(throws: AttachmentLibrary.ImportError.self) { try library.importImage(Data([1]), pathExtension: "tiff") }
        #expect(throws: AttachmentLibrary.ImportError.self) { try library.importFile(at: directory) }
    }

    /// A symlink is checked and copied as the file it names, and a link to a folder is refused.
    @Test func followsSymlinks() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = AttachmentLibrary(directory: directory.appending(path: "attachments"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appending(path: "big.txt")
        try Data(count: 4_096).write(to: target)
        let link = directory.appending(path: "link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let file = try library.importFile(at: link)
        #expect(file.byteCount == 4_096)
        #expect(file.name == "link.txt")
        #expect(try file.storedURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false)
        #expect(try Data(contentsOf: file.storedURL).count == 4_096)
        library.remove(file)
        #expect(!FileManager.default.fileExists(atPath: file.storedURL.path(percentEncoded: false)))

        let folderLink = directory.appending(path: "folder")
        try FileManager.default.createSymbolicLink(at: folderLink, withDestinationURL: directory.appending(path: "attachments"))
        #expect(throws: AttachmentLibrary.ImportError.self) { try library.importFile(at: folderLink) }
        #expect(throws: AttachmentLibrary.ImportError.self) { try library.importFile(at: directory.appending(path: "missing.txt")) }
    }
}
