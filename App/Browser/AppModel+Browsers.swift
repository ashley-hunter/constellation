import AppKit
import ConstellationCore
import Foundation

/// Browsers: a web page in a project's pile, for watching what an agent builds. A new one opens
/// straight into its panel with the address field ready.
extension AppModel {
    /// In the project of the focused card or the filter, else the first, at the dev server its
    /// shells or agents printed last.
    func openBrowser(projectID: UUID? = nil, url: URL? = nil) {
        let focused = focusedItem.flatMap { item -> UUID? in
            switch item {
            case .session(let id): sessionsByID[id]?.projectID
            case .terminal(let id): terminalsByID[id]?.projectID
            }
        }
        guard let project = project(projectID) ?? project(focused) ?? project(projectFilter) ?? projects.first else {
            notice = "Add a project to open a browser in it."
            return
        }
        let url = url ?? localServers[project.id]
        let address = url ?? URL(string: "about:blank")!
        let browser = Terminal(projectID: project.id, workingDirectory: project.rootPath, title: url?.host() ?? "New page", url: address)
        terminalsByID[browser.id] = browser
        save(browser)
        focusedItem = .terminal(browser.id)
        browserFocusesAddress = url == nil
        openTerminalView(browser.id)
    }

    /// What the address field sends.
    func navigate(_ id: UUID, to text: String) {
        guard let url = BrowserAddress.url(from: text) else { return }
        terminalsByID[id]?.url = url
        browserHost.load(url, in: id)
    }

    func observeBrowsers() {
        browserHost.onChange = { [weak self] id, title, url, isLoading in
            guard let self, var browser = terminalsByID[id] else { return }
            let before = browser
            if let url, url.absoluteString != "about:blank" { browser.url = url }
            if let title, !title.isEmpty { browser.title = title } else if let host = browser.url?.host() { browser.title = host }
            browser.state = isLoading ? .running : .idle
            guard browser != before else { return }
            terminalsByID[id] = browser
            if browser.url != before.url || browser.title != before.title { save(browser) }
        }
        browserHost.onSnapshot = { [weak self] id, image in
            self?.browserSnapshots[id] = image
            self?.browserTitleTones[id] = Self.titleTone(of: image)
        }
    }

    /// Light or dark, by the same rule as the wallpaper, over the strip of the page the card's title
    /// covers: the page is drawn filling the card's width and height, top first.
    static func titleTone(of image: NSImage) -> WallpaperTone? {
        guard let page = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let card = TileMetrics.fullSize
        let shown = Double(page.height) * max(card.width / Double(page.width), card.height / Double(page.height))
        let strip = Double(page.height) * TileMetrics.titleBarHeight / shown
        guard let top = page.cropping(to: CGRect(x: 0, y: 0, width: page.width, height: max(1, Int(strip.rounded(.up))))),
              let luminance = Wallpaper.averageLuminance(of: top) else { return nil }
        return WallpaperTone(luminance: luminance)
    }
}
