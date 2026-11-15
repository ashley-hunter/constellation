import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel(services: .live())
    private var desktop: DesktopWindowController?
    private lazy var attention = AttentionCenter(model: model)

    /// The desktop is the app's only real window, so never restore others (an open Settings window
    /// would come back on every launch and take the keyboard).
    func applicationWillFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        // Thin overlay scrollers that show while scrolling, even when the system setting is
        // "Always": the legacy scroller's track and knob are too heavy on these glass panels.
        // The app's own domain wins over the global one, and NSScroller reads it before any
        // scroll view exists.
        UserDefaults.standard.set("WhenScrolling", forKey: "AppleShowScrollBars")
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        _ = Updates.controller
        model.start()
        model.beginOnboardingIfNeeded()
        let desktop = DesktopWindowController(model: model)
        desktop.show()
        self.desktop = desktop
        attention.start()
    }

    /// A Dock click brings the desktop forward instead of opening the empty Settings scene.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        desktop?.summon()
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        desktop?.summon()
    }

    func applicationDidResignActive(_ notification: Notification) {
        desktop?.recede()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Sessions are child processes, so quitting with live ones asks first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model.hasLiveSessions {
            let alert = NSAlert()
            alert.messageText = "Quit with sessions still running?"
            alert.informativeText = "Working and blocked sessions stop now and pick up where they left off when Constellation opens again."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        Task {
            await model.shutDown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
