import AppKit
import ConstellationCore
import SwiftUI
import WebKit

/// A browser on the desktop: a snapshot of the page filling the card, which keeps running
/// offscreen, under a frosted title strip that turns light or dark with the page beneath it so the
/// title always reads. ↵, space or a click opens it.
struct BrowserTile: View {
    @Environment(AppModel.self) private var model
    @Environment(\.cardSize) private var size
    let browser: Terminal
    let project: Project?

    var body: some View {
        let isFocused = model.focusedItem == .terminal(browser.id)
        let snapshot = model.browserSnapshots[browser.id]
        ZStack(alignment: .top) {
            if let snapshot {
                // An overlay, so the page's height never pushes the card's layout.
                Color.clear.overlay(alignment: .top) { Image(nsImage: snapshot).resizable().scaledToFill() }
            } else {
                // Until the page has drawn, or for one that never draws off screen: where it is.
                VStack(spacing: 8) {
                    Image(systemName: "globe").font(.system(size: 22, weight: .light))
                    Text(browser.url?.host() ?? browser.url.map(BrowserAddressField.shown) ?? "")
                        .font(.ui(12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(Palette.textTertiary)
                .padding(.horizontal, 16)
                .padding(.top, TileMetrics.titleBarHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            let tone = snapshot == nil ? WallpaperTone.dark : model.browserTitleTones[browser.id] ?? .dark
            TerminalTitleBar(terminal: browser, project: project, tone: tone)
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial)
                .background(tone == .light ? Color.white.opacity(0.55) : Color.black.opacity(0.45))
                .environment(\.colorScheme, tone == .light ? .light : .dark)
        }
        .frame(width: size.width, height: size.height)
        .panelSurface(.card, edge: isFocused ? Palette.edge : .white.opacity(0.12))
        // A restored browser loads its page offscreen, so its card has something to show.
        .task(id: browser.id) { _ = model.browserHost.view(for: browser) }
        .contextMenu {
            ActionButton(.tileOpen, on: .terminal(browser.id), title: "Open")
            ActionButton(.terminalClose, on: .terminal(browser.id), title: "Close browser")
        }
    }
}

/// ↵ on a browser card: the page, larger and taking the keyboard, under a header with back,
/// forward, reload and the address.
struct OpenedBrowserPanel: View {
    @Environment(AppModel.self) private var model
    let browser: Terminal
    @Environment(\.presentationIsSettled) private var isSettled

    static func frame(in size: CGSize) -> CGRect {
        let width = min(BrowserHost.pageSize.width, size.width - 64)
        let height = min(BrowserHost.pageSize.height, size.height - 80)
        return CGRect(x: ((size.width - width) / 2).rounded(), y: ((size.height - height) / 2).rounded(), width: max(width, 0), height: max(height, 0))
    }

    var body: some View {
        VStack(spacing: 0) {
            BrowserPanelHeader(browser: browser)
            // Like the shell, the page joins once the panel has grown and leaves as it shrinks.
            ZStack {
                if isSettled {
                    BrowserSurface(browser: browser)
                        .id(browser.id)
                        .transition(.opacity.animation(.fadeIn))
                } else if let snapshot = model.browserSnapshots[browser.id] {
                    Color.clear.overlay(alignment: .top) { Image(nsImage: snapshot).resizable().scaledToFill() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: PanelSurface.cornerRadius, bottomTrailingRadius: PanelSurface.cornerRadius, style: .continuous))
        }
        .panelSurface()
    }
}

private struct BrowserPanelHeader: View {
    @Environment(AppModel.self) private var model
    let browser: Terminal

    var body: some View {
        PanelHeader {
            TerminalGlyph(state: browser.state, kind: .browser)
            if let project = model.project(browser.projectID) { ProjectMark(project: project) }
            HStack(spacing: 2) {
                navButton("chevron.left", help: "Back") { $0.goBack() }
                navButton("chevron.right", help: "Forward") { $0.goForward() }
                navButton(browser.state == .running ? "xmark" : "arrow.clockwise", help: browser.state == .running ? "Stop" : "Reload") {
                    if $0.isLoading { $0.stopLoading() } else { $0.reload() }
                }
            }
            BrowserAddressField(browser: browser)
        } trailing: {
            PanelMaximiseButton()
            PanelOverflowMenu(help: "More: open in your browser, copy address, close") {
                if let url = browser.url {
                    Button("Open in Default Browser") { NSWorkspace.shared.open(url) }
                    Button("Copy Address") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    }
                }
                Divider()
                ActionButton(.tileClose, on: .terminal(browser.id), title: "Close browser")
            }
            PanelBackButton()
        }
    }

    private func navButton(_ symbol: String, help: String, action: @escaping (WKWebView) -> Void) -> some View {
        Button {
            if let view = model.browserHost.webView(browser.id) { action(view) }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(IconButtonStyle(width: 24, height: 24))
        .help(help)
    }
}

/// The page's address, without the scheme for http and https; editing it and pressing ↵ loads
/// what you typed.
struct BrowserAddressField: View {
    @Environment(AppModel.self) private var model
    let browser: Terminal
    @State private var text = ""
    @FocusState private var isFocused: Bool

    static func shown(_ url: URL) -> String {
        guard url.absoluteString != "about:blank" else { return "" }
        let text = url.absoluteString.replacing(/^https?:\/\//, with: "")
        return text.hasSuffix("/") && text.filter { $0 == "/" }.count == 1 ? String(text.dropLast()) : text
    }

    var body: some View {
        TextField("Address, or a port like :5173", text: $text)
            .textFieldStyle(.plain)
            .font(.ui(12))
            .foregroundStyle(isFocused ? Palette.text : Palette.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Palette.text.opacity(isFocused ? 0.1 : 0.06), in: .rect(cornerRadius: Radius.control, style: .continuous))
            .frame(maxWidth: 520)
            .focused($isFocused)
            .onSubmit {
                model.navigate(browser.id, to: text)
                text = model.terminalsByID[browser.id]?.url.map(Self.shown) ?? text
                isFocused = false
            }
            .onAppear {
                text = browser.url.map(Self.shown) ?? ""
                if model.browserFocusesAddress {
                    model.browserFocusesAddress = false
                    isFocused = true
                }
            }
            .onChange(of: browser.url) { _, url in
                if !isFocused { text = url.map(Self.shown) ?? "" }
            }
    }
}

/// The browser's web view, moved in from the offscreen window while this is on screen and back
/// when it leaves.
struct BrowserSurface: NSViewRepresentable {
    @Environment(AppModel.self) private var model
    let browser: Terminal

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let view = model.browserHost.view(for: browser)
        view.removeFromSuperview()
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        context.coordinator.view = view
        context.coordinator.host = model.browserHost
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_ container: NSView, coordinator: Coordinator) {
        guard let view = coordinator.view, view.superview === container else { return }
        coordinator.host?.park(view)
    }

    final class Coordinator {
        weak var view: WKWebView?
        weak var host: BrowserHost?
    }
}
