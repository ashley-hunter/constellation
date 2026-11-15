import AppKit
import ConstellationCore
import Foundation

/// Finds a picture for a project: a favicon, logo or app icon in its repository, else the avatar
/// of the GitHub organisation it belongs to. A personal account's avatar would be the same face on
/// every project, so it's left out.
enum ProjectIcon {
    /// Where web apps, docs sites and Apple apps usually keep theirs, nearest the root first.
    private static let folders = ["", "public", "static", "assets", "app", "src", "src/app", "web", "docs", "docs/public", ".github", "images", "img", "resources"]
    private static let names = ["favicon.svg", "icon.svg", "logo.svg", "apple-touch-icon.png", "icon.png", "logo.png", "favicon.png", "favicon.ico"]

    /// A picture in the repository, or nil. Reads the disk, so off the main actor.
    static func local(in root: URL) -> NSImage? {
        let files = FileManager.default
        var candidates = folders.flatMap { folder in names.map { root.appending(path: folder).appending(path: $0) } }
        // A monorepo's apps, and an Xcode project's app icon.
        for parent in ["apps", "packages"] {
            for app in (try? files.contentsOfDirectory(atPath: root.appending(path: parent).path(percentEncoded: false))) ?? [] {
                candidates += ["public", "app", "src/app", ""].flatMap { folder in names.map { root.appending(path: "\(parent)/\(app)/\(folder)").appending(path: $0) } }
            }
        }
        candidates += appIconSet(in: root)
        for url in candidates where files.fileExists(atPath: url.path(percentEncoded: false)) {
            if let image = NSImage(contentsOf: url), image.isValid, image.size.width >= 16 { return image }
        }
        return nil
    }

    /// The largest picture in the first `AppIcon.appiconset` within a few folders of the root.
    private static func appIconSet(in root: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        for case let url as URL in walker {
            let depth = url.pathComponents.count - root.pathComponents.count
            if depth > 5 || ["node_modules", "build", "DerivedData", "Pods", ".build", "dist"].contains(url.lastPathComponent) {
                walker.skipDescendants()
                continue
            }
            guard url.lastPathComponent == "AppIcon.appiconset" else { continue }
            let pngs = ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])) ?? []).filter { $0.pathExtension == "png" }
            return pngs.sorted { (size(of: $0)) > (size(of: $1)) }.prefix(1).map(\.self)
        }
        return []
    }

    private static func size(of url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    /// The GitHub owner in the repository's origin remote, read from `.git/config`.
    static func githubOwner(of root: URL) -> String? {
        guard let config = try? String(contentsOf: root.appending(path: ".git/config"), encoding: .utf8) else { return nil }
        for line in config.split(separator: "\n") where line.contains("url =") && line.contains("github.com") {
            let rest = line.split(separator: "github.com", maxSplits: 1).last ?? ""
            let owner = rest.trimmingCharacters(in: CharacterSet(charactersIn: ":/ ")).split(separator: "/").first
            if let owner, !owner.isEmpty { return String(owner) }
        }
        return nil
    }

    /// The owner's avatar when it's an organisation. ponytail: unauthenticated, so 60 lookups an
    /// hour; fine once a launch per project.
    static func organisationAvatar(_ owner: String) async -> NSImage? {
        struct Account: Decodable {
            let type: String
            let avatar_url: URL
        }
        guard let url = URL(string: "https://api.github.com/users/\(owner)"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let account = try? JSONDecoder().decode(Account.self, from: data), account.type == "Organization",
              var avatar = URLComponents(url: account.avatar_url, resolvingAgainstBaseURL: false) else { return nil }
        avatar.queryItems = (avatar.queryItems ?? []) + [URLQueryItem(name: "s", value: "64")]
        guard let avatarURL = avatar.url, let (image, _) = try? await URLSession.shared.data(from: avatarURL) else { return nil }
        return NSImage(data: image)
    }
}

extension AppModel {
    /// Looks once for each project's icon, nearest first: the repository, then its organisation.
    func findProjectIcons() async {
        for project in projects where !projectIconsSought.contains(project.id) {
            projectIconsSought.insert(project.id)
            let root = project.rootPath
            let found = await Task.detached(priority: .utility) { () -> (NSImage?, String?) in
                (ProjectIcon.local(in: root), ProjectIcon.githubOwner(of: root))
            }.value
            if let image = found.0 {
                projectIcons[project.id] = image
            } else if let owner = found.1, let avatar = await ProjectIcon.organisationAvatar(owner) {
                projectIcons[project.id] = avatar
            }
        }
    }
}
