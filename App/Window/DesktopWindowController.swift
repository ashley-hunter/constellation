import AppKit
import ConstellationCore
import SwiftUI

/// Owns the one desktop window: borderless, transparent, on every Space, covering the primary display's
/// visible frame. It starts at desktop level and checks that it really becomes key; if not, it falls
/// back to normal level with the same window and draws the wallpaper itself.
@MainActor
final class DesktopWindowController {
    let window: DesktopWindow
    let appearance = DesktopAppearance()
    private let model: AppModel
    private var keyMonitor: Any?
    private var flagsMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var sawKeyDown = false
    private var keyFocusJudged = false

    init(model: AppModel) {
        self.model = model
        window = DesktopWindow(
            contentRect: NSScreen.screens.first?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.acceptsMouseMovedEvents = true
        let hostingView = NSHostingView(rootView: DesktopView().environment(model).environment(appearance))
        // The window always covers the screen; never let SwiftUI grow it to fit the desktop's content.
        hostingView.sizingOptions = []
        window.contentView = hostingView
        window.onKeyDown = { [weak self] event in self?.noteKeyDown(event) }
        // `-ConstellationForceLevel normal` tries the fallback without waiting for the check to fail.
        apply(UserDefaults.standard.string(forKey: "ConstellationForceLevel").flatMap(DesktopAppearance.Level.init) ?? .desktop)
        installKeyMonitor()
        observeScreenAndWallpaper()
        watchBackground()
        window.onFirstResponderChange = { [weak self] in
            guard let self else { return }
            self.model.keyboard.isEditingText = self.isEditingText
        }
        model.keyboard.start(model: model)
    }

    func show() {
        reframe()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        scheduleKeyFocusCheck(after: .milliseconds(700))
    }

    /// Activating the app (Dock click, ⌘-Tab) lifts the desktop above other windows, drawing the
    /// wallpaper behind the tiles; switching away sinks it back to desktop level.
    func summon() {
        if appearance.level == .desktop {
            appearance.level = .normal
            window.level = .normal
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func recede() {
        guard appearance.level == .normal, UserDefaults.standard.string(forKey: "DesktopWindowLevel") == DesktopAppearance.Level.desktop.rawValue else { return }
        appearance.level = .desktop
        window.level = DesktopWindow.desktopLevel()
        window.orderFront(nil)
    }

    private func scheduleKeyFocusCheck(after delay: Duration) {
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            self?.verifyKeyFocus()
        }
    }

    private func apply(_ level: DesktopAppearance.Level) {
        appearance.level = level
        window.level = level == .desktop ? DesktopWindow.desktopLevel() : .normal
        UserDefaults.standard.set(level.rawValue, forKey: "DesktopWindowLevel")
    }

    private func reframe() {
        guard let screen = NSScreen.screens.first else { return }
        window.setFrame(screen.visibleFrame, display: true)
        let background = Background.named(model.settings.background)
        appearance.background = background
        guard let url = background?.url ?? Wallpaper.url(for: screen), url != appearance.wallpaper.url else { return }
        let maxPixelSize = Int(max(screen.frame.width, screen.frame.height) * screen.backingScaleFactor)
        appearance.wallpaper.url = url
        Task { [weak self] in
            let wallpaper = await Wallpaper.load(url, maxPixelSize: maxPixelSize)
            guard let self, self.appearance.wallpaper.url == url else { return }
            self.appearance.wallpaper = wallpaper
            Log.window.notice("Wallpaper luminance \(wallpaper.luminance ?? -1)")
        }
    }

    // MARK: Key focus check

    /// Logs whether the window became key at its level, and falls back to normal level when it didn't.
    /// Only judged while the app is active: launched in the background, no window can be key, so the
    /// check waits for the first activation. Launch with `-ConstellationKeyProbe YES` to also post a
    /// key event and log that it arrived.
    private func verifyKeyFocus() {
        guard !keyFocusJudged else { return }
        guard NSApp.isActive else {
            Log.window.notice("Key focus check deferred: app inactive, level=\(self.appearance.level.rawValue, privacy: .public)")
            return
        }
        let isKey = window.isKeyWindow
        Log.window.notice("Key focus check: level=\(self.appearance.level.rawValue, privacy: .public) rawLevel=\(self.window.level.rawValue) isKeyWindow=\(isKey) appActive=\(NSApp.isActive)")
        if !isKey, appearance.level == .desktop {
            Log.window.notice("Desktop level did not take key focus; falling back to normal level")
            apply(.normal)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            scheduleKeyFocusCheck(after: .milliseconds(500))
            return
        }
        keyFocusJudged = true
        if UserDefaults.standard.bool(forKey: "ConstellationKeyProbe") { postProbeKey() }
    }

    private func postProbeKey() {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\u{F8FF}", charactersIgnoringModifiers: "\u{F8FF}",
            isARepeat: false, keyCode: 0x7F
        ) else { return }
        NSApp.postEvent(event, atStart: false)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self else { return }
            Log.window.notice("Key probe: posted keyDown received=\(self.sawKeyDown)")
        }
    }

    private func noteKeyDown(_ event: NSEvent) {
        guard !sawKeyDown else { return }
        sawKeyDown = true
        Log.window.notice("First keyDown reached the desktop window: level=\(self.appearance.level.rawValue, privacy: .public) keyCode=\(event.keyCode)")
    }

    // MARK: Keys

    /// Keys run registered actions (single-letter ones only when no text field is editing).
    /// Any other printable key on a focused session tile opens its inline composer, and ⌘V in a
    /// composer takes images and files as attachments.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.window != nil else { return event }
            let isOurs = event.window === self?.window
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, isOurs else { return false }
                let inShell = self.window.firstResponder is ShellTerminalView
                let isEditingText = self.isEditingText
                if DesktopKeys.isPaste(event), isEditingText, !inShell {
                    return self.model.pasteAttachments(from: .general)
                }
                // The launcher's filter takes letters ahead of the desktop's keys.
                if self.model.launcherTakesKeys, !isEditingText, !self.model.keyboard.isSequencePending,
                   let text = DesktopKeys.typedText(event), !text.contains(where: \.isWhitespace) {
                    return self.model.startTyping(text)
                }
                if let stroke = KeyStroke(event) {
                    self.noteKeyDown(event)
                    // Esc at a shell's prompt puts its window away; while a command runs, vim and less keep it.
                    let shellKeepsEscape = (self.window.firstResponder as? ShellTerminalView)?.isAtPrompt == false
                    if self.model.handleKey(stroke, isEditingText: isEditingText, inShell: inShell, shellKeepsEscape: shellKeepsEscape) { return true }
                }
                guard !isEditingText, let text = DesktopKeys.typedText(event) else { return false }
                return self.model.startTyping(text)
            }
            return handled ? nil : event
        }
        // Holding ⌘ alone shows the digit badges, ⌃ the project numbers, ⌥ the launcher's keys.
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            MainActor.assumeIsolated {
                guard let model = self?.model else { return }
                model.keyboard.commandChanged(isHeldAlone: flags == .command && !model.isDesktopCovered)
                model.keyboard.controlChanged(isHeldAlone: flags == .control && !model.isDesktopCovered && !model.keyboard.isEditingText)
                model.keyboard.optionChanged(isHeldAlone: flags == .option && model.launcherTakesKeys)
            }
            return event
        }
    }

    /// A text field, terminal or web page has the keys. ⌘ chords and esc still reach the desktop.
    private var isEditingText: Bool {
        window.firstResponder is ShellTerminalView || (window.firstResponder as? NSTextView)?.isEditable == true || window.firstResponder?.isInWebView == true
    }

    // MARK: Screen and wallpaper

    /// Picking another background in Settings or onboarding swaps it in straight away.
    private func watchBackground() {
        withObservationTracking { _ = model.settings.background } onChange: { [weak self] in
            Task { @MainActor in
                self?.reframe()
                self?.watchBackground()
            }
        }
    }

    private func observeScreenAndWallpaper() {
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reframe() }
            },
            workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reframe() }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.appearance.isActive = false
                    self?.model.keyboard.commandChanged(isHeldAlone: false)
                    self?.model.keyboard.controlChanged(isHeldAlone: false)
                    self?.model.keyboard.optionChanged(isHeldAlone: false)
                }
            },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.appearance.isActive = true
                    self.reframe()
                    Log.window.notice("Became active: isKeyWindow=\(self.window.isKeyWindow)")
                    if !self.keyFocusJudged { self.scheduleKeyFocusCheck(after: .milliseconds(300)) }
                }
            },
        ]
    }
}
