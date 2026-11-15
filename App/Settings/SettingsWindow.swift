import AppKit
import SwiftUI

/// The Settings window, opened from ⌘, or the menu. Kept out of SwiftUI's scenes so it never opens by itself.
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    func show(model: AppModel) {
        if window == nil {
            let window = ClosingWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            window.title = "Constellation Settings"
            // Our own surface edge to edge: the title bar is transparent and the traffic lights sit
            // over the section rail.
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.backgroundColor = NSColor(Palette.popover)
            window.appearance = NSAppearance(named: .darkAqua)
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func close() {
        window?.close()
    }
}

/// The menu's ⌘W closes desktop tiles, so this window takes ⌘W first and closes itself.
private final class ClosingWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
