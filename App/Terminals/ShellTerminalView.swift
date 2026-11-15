import AppKit
import ConstellationCore
import ConstellationProcess
import Foundation
import GhosttyTerminal
import Synchronization

/// Ghostty's terminal view, drawing a shell we spawn on our own pty (``PseudoTerminal``). Its
/// output passes through a ``ShellMarkScanner`` on the way in, so we hear OSC 133 marks while
/// Ghostty still sees every byte, marks included. It tells us when it takes keyboard focus or its
/// shell exits.
///
/// The shell starts only once Ghostty has laid out a grid at the view's real size, and at that size.
/// Started any earlier, zsh would print its first prompt for a width the grid doesn't have (80
/// columns, or the placeholder size Ghostty gives a new surface), and the soft-wrapped rows would
/// join back up when the grid grows, leaving the prompt far along the line after zsh's `%` mark.
/// From then on the pty's size follows the grid, set by Ghostty as it resizes.
final class ShellTerminalView: AppTerminalView, TerminalSurfaceLifecycleDelegate, TerminalSurfaceGridResizeDelegate {
    var onMark: ((ShellMark) -> Void)?
    /// A dev server's address went past, for a new browser to open.
    var onLocalServer: ((URL) -> Void)?
    var onExit: ((Int32?) -> Void)?
    var onFocus: (() -> Void)?
    /// The shell has shown its prompt and runs nothing. False until its first mark, so a shell
    /// without the integration keeps esc.
    private(set) var isAtPrompt = false
    /// Shown on a tile: it can't take the keyboard, and lets it go if it had it.
    var isInert = false {
        didSet {
            guard isInert, let window, window.firstResponder === self else { return }
            window.makeFirstResponder(nil)
        }
    }

    private let link = ShellLink()
    /// The last few thousand characters it printed, for a task's card to read why it failed.
    private let tail = OutputTail()
    private let session: InMemoryTerminalSession
    /// The size asked for before the surface existed, applied once it does.
    private var pendingFontSize: Float?
    private var appliedFontSize: Float?
    /// What to start, held until the grid has its first real size.
    private var pendingLaunch: ShellLaunch?
    private var gridSize: (columns: Int, rows: Int)?

    init() {
        let link = link
        session = InMemoryTerminalSession(
            write: { link.write($0) },
            resize: { link.resize($0) }
        )
        super.init(frame: NSRect(x: 0, y: 0, width: 480, height: 280))
        delegate = self
        controller = TerminalAppearance.controller
        configuration = TerminalSurfaceOptions(backend: .inMemory(session))
    }

    /// Starts the shell, now if the grid is laid out, else as soon as it is.
    func start(_ launch: ShellLaunch) {
        guard !link.hasStarted else { return }
        pendingLaunch = launch
        startIfReady()
    }

    private func startIfReady() {
        guard let launch = pendingLaunch, let (columns, rows) = gridSize, !link.hasStarted else { return }
        pendingLaunch = nil
        let (session, scanner) = (session, MarkScanner())
        if let history = launch.tmux?.history, !history.isEmpty {
            // Pushed past the screen, so it's scrollback before tmux redraws the screen it kept.
            let lines = String(decoding: history, as: UTF8.self).replacingOccurrences(of: "\n", with: "\r\n")
            session.receive(Data((lines + String(repeating: "\r\n", count: rows)).utf8))
        }
        do {
            let spawn = try launch.spawn()
            let terminal = try link.start {
                try PseudoTerminal(
                    executable: spawn.executable,
                    arguments: spawn.arguments,
                    argv0: spawn.argv0,
                    environment: spawn.environment,
                    currentDirectory: launch.directory,
                    columns: columns,
                    rows: rows
                )
            }
            let tail = tail
            terminal.startReading { [weak self] data in
                let marks = scanner.scan(data)
                session.receive(data)
                tail.append(data)
                // A server's address split across two reads is missed; the next one it prints is not.
                if data.range(of: Data("://".utf8)) != nil, let url = LocalServer.url(in: String(decoding: data, as: UTF8.self)) {
                    DispatchQueue.main.async { [weak self] in self?.onLocalServer?(url) }
                }
                guard !marks.isEmpty else { return }
                DispatchQueue.main.async { [weak self] in
                    for mark in marks {
                        self?.isAtPrompt = mark != .commandStarted
                        self?.onMark?(mark)
                    }
                }
            }
            terminal.process.onExit { [weak self] code in
                DispatchQueue.main.async { [weak self] in self?.onExit?(code) }
            }
        } catch {
            Log.app.error("Starting a shell failed: \(error, privacy: .public)")
            session.receive("Constellation could not start a shell: \(error.localizedDescription)\r\n")
            onExit?(nil)
        }
    }

    /// What it has printed lately, escape sequences and all.
    var recentOutput: String { tail.text.withLock { $0 } }

    /// Starts the tail afresh, as a task's command runs again.
    func clearRecentOutput() { tail.text.withLock { $0 = "" } }

    /// Types into the shell as if from the keyboard.
    func send(text: String) {
        link.write(Data(text.utf8))
    }

    /// Hangs up the shell, as closing a terminal window does.
    func terminate() {
        link.hangUp()
    }

    /// Point size for where the view is shown. Set before it joins a window, it is the size the
    /// surface starts at; after that Ghostty changes it in place, keeping the scrollback.
    var pointSize: Float? {
        get { appliedFontSize ?? pendingFontSize }
        set {
            guard let newValue, newValue != pointSize else { return }
            if performBindingAction("set_font_size:\(newValue)") {
                appliedFontSize = newValue
            } else {
                pendingFontSize = newValue
                if window == nil { configuration.fontSize = newValue }
            }
        }
    }

    override var acceptsFirstResponder: Bool {
        !isInert && super.acceptsFirstResponder
    }

    override var canBecomeKeyView: Bool {
        !isInert && super.canBecomeKeyView
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus?() }
        return became
    }

    /// The menu bar's shortcuts come first, as in any other view; Ghostty's own bindings (copy,
    /// paste, clear) get what the menus don't use.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: TerminalSurfaceLifecycleDelegate

    func terminalDidAttachSurface(_ surface: GhosttyTerminal.TerminalSurface) {
        appliedFontSize = configuration.fontSize
        guard let pendingFontSize else { return }
        self.pendingFontSize = nil
        pointSize = pendingFontSize
    }

    func terminalDidDetachSurface() {}

    // MARK: TerminalSurfaceGridResizeDelegate

    /// The grid the view has just been laid out at, the size the shell starts at.
    func terminalDidResize(_ size: TerminalGridMetrics) {
        guard size.columns > 0, size.rows > 0, !link.hasStarted else { return }
        gridSize = (Int(size.columns), Int(size.rows))
        startIfReady()
    }
}

/// What the session's callbacks (on Ghostty's threads) share with the view: the pty once it
/// exists. Ghostty reports each grid size just before it lays the grid out at it, which is when the
/// pty takes it too.
private final class ShellLink: Sendable {
    private struct State {
        var terminal: PseudoTerminal?
        var started = false
    }

    private let state = Mutex(State())

    var hasStarted: Bool { state.withLock { $0.started } }

    func start(_ make: () throws -> PseudoTerminal) throws -> PseudoTerminal {
        try state.withLock { state in
            state.started = true
            let terminal = try make()
            state.terminal = terminal
            return terminal
        }
    }

    func write(_ data: Data) {
        state.withLock { $0.terminal }?.write(data)
    }

    func resize(_ viewport: InMemoryTerminalViewport) {
        state.withLock { $0.terminal }?.resize(
            columns: Int(viewport.columns), rows: Int(viewport.rows),
            widthPixels: Int(viewport.widthPixels), heightPixels: Int(viewport.heightPixels)
        )
    }

    func hangUp() {
        state.withLock { $0.terminal }?.hangUp()
    }
}

/// A ``ShellMarkScanner`` for the pty's reader thread.
private final class MarkScanner: Sendable {
    private let scanner = Mutex(ShellMarkScanner())

    func scan(_ data: Data) -> [ShellMark] {
        scanner.withLock { $0.scan(data) }
    }
}

/// The end of a shell's output, written from its reading thread and read on the main actor.
private final class OutputTail: Sendable {
    let text = Mutex("")

    func append(_ data: Data) {
        text.withLock { text in
            text += String(decoding: data, as: UTF8.self)
            if text.count > 6000 { text.removeFirst(text.count - 4000) }
        }
    }
}
