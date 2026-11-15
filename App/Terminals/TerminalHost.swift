import AppKit
import ConstellationCore

/// Owns each terminal's shell view, apart from any SwiftUI view, so a shell keeps running while its
/// tile is filtered out, and one shell can move between its tile, the larger view and the split
/// focus Terminal tab. The most recently attached holder you can type in shows it, ahead of any
/// tile's; detaching hands it back.
@MainActor
final class TerminalHost {
    private var shells: [UUID: ShellTerminalView] = [:]
    private var holders: [UUID: [TerminalHolder]] = [:]

    func hasShell(_ id: UUID) -> Bool {
        shells[id] != nil
    }

    func add(_ shell: ShellTerminalView, for id: UUID) {
        shells[id] = shell
        place(id)
    }

    func attach(_ holder: TerminalHolder, to id: UUID) {
        holders[id, default: []].removeAll { $0 === holder }
        holders[id, default: []].append(holder)
        place(id)
    }

    func detach(_ holder: TerminalHolder, from id: UUID) {
        let wasShowing = shown(id) === holder
        holders[id]?.removeAll { $0 === holder }
        if holders[id]?.isEmpty == true { holders[id] = nil }
        if wasShowing { place(id) }
    }

    /// Types into the shell, as if from the keyboard.
    func send(_ text: String, to id: UUID) {
        shells[id]?.send(text: text)
    }

    func recentOutput(of id: UUID) -> String {
        shells[id]?.recentOutput ?? ""
    }

    func clearRecentOutput(of id: UUID) {
        shells[id]?.clearRecentOutput()
    }

    /// Stops the shell. Its exit is not reported, since closing is what you asked for.
    func close(_ id: UUID) {
        guard let shell = shells.removeValue(forKey: id) else { return }
        shell.onExit = nil
        shell.onMark = nil
        shell.onLocalServer = nil
        shell.onFocus = nil
        shell.terminate()
        shell.removeFromSuperview()
    }

    func closeAll() {
        for id in Array(shells.keys) { close(id) }
    }

    /// A tile's card coming back (as its pile changes after a merge) mustn't take the shell from the
    /// session view's Terminal pane or the opened terminal, leaving them blank.
    private func shown(_ id: UUID) -> TerminalHolder? {
        holders[id]?.last(where: { !$0.isInert }) ?? holders[id]?.last
    }

    private func place(_ id: UUID) {
        guard let shell = shells[id] else { return }
        if let holder = shown(id) {
            // Already there: holding it again would take the keyboard back from wherever it went.
            if shell.superview !== holder { holder.hold(shell) }
        } else {
            shell.removeFromSuperview()
        }
    }
}

/// The NSView a ``TerminalSurface`` puts in the SwiftUI hierarchy. It sizes the shell view to fit,
/// sets its font for this place, and gives it keyboard focus when asked to. An inert one (a tile on
/// the desktop) only shows the shell: clicks, scrolls and keys pass to the desktop around it.
final class TerminalHolder: NSView {
    var fontSize: CGFloat {
        didSet { if fontSize != oldValue { shell?.pointSize = Float(fontSize) } }
    }

    var takesFocus: Bool
    var isInert: Bool {
        didSet { shell?.isInert = isInert }
    }
    var onDismantle: (() -> Void)?

    init(fontSize: CGFloat, takesFocus: Bool, isInert: Bool) {
        self.fontSize = fontSize
        self.takesFocus = takesFocus
        self.isInert = isInert
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var shell: ShellTerminalView? {
        subviews.first as? ShellTerminalView
    }

    func hold(_ shell: ShellTerminalView) {
        // Sized first, so a shell seen for the first time starts at this place's size.
        shell.pointSize = Float(fontSize)
        shell.isInert = isInert
        if shell.superview !== self {
            shell.removeFromSuperview()
            shell.frame = bounds
            shell.autoresizingMask = [.width, .height]
            addSubview(shell)
        }
        focusIfAsked()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isInert ? nil : super.hitTest(point)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusIfAsked()
    }

    private func focusIfAsked() {
        guard takesFocus, let shell, let window else { return }
        window.makeFirstResponder(shell)
    }
}
