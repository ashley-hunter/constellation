import AppKit
import UniformTypeIdentifiers

/// A picture for behind the desktop in place of your own wallpaper: one that ships with the app, or
/// an image of yours, whose id is its path. NASA's own photos and Hokusai's prints are public
/// domain, ESA/Webb's are CC BY 4.0, and the theme ones are drawn by `scripts/generate-backgrounds.swift`
/// in each editor theme's palette; each shows its credit wherever it does.
struct Background: Identifiable, Hashable {
    let id: String
    let title: String
    var credit = ""

    var isYours: Bool { id.hasPrefix("/") }

    var url: URL? {
        isYours ? URL(filePath: id) : Bundle.main.url(forResource: id, withExtension: "jpg", subdirectory: "Backgrounds")
    }

    static let all = [
        Background(id: "cosmic-cliffs", title: "Cosmic Cliffs", credit: "NASA, ESA, CSA, and STScI"),
        Background(id: "pillars-of-creation", title: "Pillars of Creation", credit: "NASA, ESA, CSA, STScI; J. DePasquale, A. Koekemoer, A. Pagan (STScI)"),
        Background(id: "aurora", title: "Aurora from the ISS", credit: "NASA"),
        Background(id: "earthset", title: "Earthset, Artemis II", credit: "NASA"),
        Background(id: "earthrise", title: "Earthrise, Apollo 8", credit: "NASA"),
        Background(id: "great-wave", title: "The Great Wave", credit: "Katsushika Hokusai, c. 1831"),
        Background(id: "red-fuji", title: "Red Fuji", credit: "Katsushika Hokusai, c. 1831"),
        Background(id: "summit-storm", title: "Storm below the Summit", credit: "Katsushika Hokusai, c. 1831"),
        Background(id: "kajikazawa", title: "Kajikazawa", credit: "Katsushika Hokusai, c. 1831"),
        Background(id: "tokyo-night", title: "Tokyo Night"),
        Background(id: "kanagawa", title: "Kanagawa"),
        Background(id: "nord", title: "Nord"),
        Background(id: "catppuccin", title: "Catppuccin"),
        Background(id: "gruvbox", title: "Gruvbox"),
    ]

    static func named(_ id: String?) -> Background? {
        guard let id else { return nil }
        if id.hasPrefix("/") { return Background(id: id, title: URL(filePath: id).deletingPathExtension().lastPathComponent) }
        return all.first { $0.id == id }
    }

    /// Asks for an image of yours, returning its path, which the setting keeps. ponytail: kept where
    /// it is, so moving or deleting it brings back the plain backdrop; copy it in if that bites.
    @MainActor
    static func chooseYourOwn() -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.prompt = "Use"
        panel.message = "Choose an image for behind your piles."
        guard panel.runModal() == .OK else { return nil }
        return panel.url?.path(percentEncoded: false)
    }
}
