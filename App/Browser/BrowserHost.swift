import AppKit
import ConstellationCore
import WebKit

/// Owns each browser's web view, apart from any SwiftUI view, so a page keeps running (a dev
/// server's hot reload, a login) while its card is filtered out or its panel closed. A view not in
/// the panel waits in an offscreen window, where it still renders, so its card can show a snapshot.
@MainActor
final class BrowserHost: NSObject, WKNavigationDelegate, WKUIDelegate {
    /// The page's title, address or loading changed.
    var onChange: ((UUID, _ title: String?, _ url: URL?, _ isLoading: Bool) -> Void)?
    var onSnapshot: ((UUID, NSImage) -> Void)?

    private var views: [UUID: WKWebView] = [:]
    private var observations: [UUID: [NSKeyValueObservation]] = [:]
    private var snapshotTasks: [UUID: Task<Void, Never>] = [:]
    /// The size pages lay out at off the panel, the panel's own, so a snapshot looks like the page.
    static let pageSize = CGSize(width: 1200, height: 780)

    private lazy var parking: NSWindow = {
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -30_000, y: -30_000), size: Self.pageSize), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.contentView = NSView(frame: CGRect(origin: .zero, size: Self.pageSize))
        window.orderFrontRegardless()
        return window
    }()

    /// The browser's web view, made and loading the first time it's asked for.
    func view(for browser: Terminal) -> WKWebView {
        if let view = views[browser.id] { return view }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let view = WKWebView(frame: CGRect(origin: .zero, size: Self.pageSize), configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        views[browser.id] = view
        let id = browser.id
        let report: (WKWebView) -> Void = { [weak self] view in
            MainActor.assumeIsolated { self?.onChange?(id, view.title, view.url, view.isLoading) }
        }
        observations[id] = [
            view.observe(\.title) { view, _ in report(view) },
            view.observe(\.url) { view, _ in report(view) },
            view.observe(\.isLoading) { view, _ in report(view) },
        ]
        park(view)
        if let url = browser.url { view.load(URLRequest(url: url)) }
        return view
    }

    func load(_ url: URL, in id: UUID) {
        views[id]?.load(URLRequest(url: url))
    }

    func webView(_ id: UUID) -> WKWebView? {
        views[id]
    }

    /// Back to the offscreen window, snapshotting the page as it was last seen.
    func park(_ view: WKWebView) {
        guard view.superview !== parking.contentView else { return }
        view.removeFromSuperview()
        view.frame = CGRect(origin: .zero, size: Self.pageSize)
        parking.contentView?.addSubview(view)
        if let id = views.first(where: { $0.value === view })?.key { snapshot(id) }
    }

    func close(_ id: UUID) {
        snapshotTasks.removeValue(forKey: id)?.cancel()
        observations[id] = nil
        guard let view = views.removeValue(forKey: id) else { return }
        view.stopLoading()
        view.removeFromSuperview()
    }

    /// A moment after the page settles, so what's drawn is the page and not its first paint. A page
    /// that's still one flat colour (an app's splash while its script runs) is tried again a few
    /// times; one still blank at the end isn't kept, so the card shows its placeholder instead.
    func snapshot(_ id: UUID) {
        snapshotTasks[id]?.cancel()
        snapshotTasks[id] = Task { [weak self] in
            for wait in [600, 1500, 3000, 6000] {
                try? await Task.sleep(for: .milliseconds(wait))
                guard !Task.isCancelled, let view = self?.views[id], let image = try? await view.takeSnapshot(configuration: nil) else { return }
                if !Self.isBlank(image) {
                    self?.onSnapshot?(id, image)
                    return
                }
            }
        }
    }

    /// Nearly every pixel the same: a 16 point copy's brightest and darkest differ by under 4%.
    static func isBlank(_ image: NSImage) -> Bool {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return false }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: 16, height: 16))
        let lights = (0..<256).map { Int(data[$0 * 4]) + Int(data[$0 * 4 + 1]) + Int(data[$0 * 4 + 2]) }
        return (lights.max() ?? 0) - (lights.min() ?? 0) < 30
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let id = views.first(where: { $0.value === webView })?.key { snapshot(id) }
    }

    // MARK: WKUIDelegate

    /// A link that asks for a new window opens in this one.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil, let url = action.request.url { webView.load(URLRequest(url: url)) }
        return nil
    }
}

extension NSResponder {
    /// A web page, or something inside one, has the keys.
    var isInWebView: Bool {
        var view = self as? NSView
        while let current = view {
            if current is WKWebView { return true }
            view = current.superview
        }
        return false
    }
}
