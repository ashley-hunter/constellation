import AppKit

/// A borderless window that can still become key, so the desktop takes keyboard input.
final class DesktopWindow: NSWindow {
    /// Called for every key down the window receives, for the key-focus check.
    var onKeyDown: ((NSEvent) -> Void)?

    /// Called after the first responder changes, so keys know whether a text field has them.
    var onFirstResponderChange: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let changed = super.makeFirstResponder(responder)
        onFirstResponderChange?()
        return changed
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown { onKeyDown?(event) }
        super.sendEvent(event)
    }

    static func desktopLevel() -> NSWindow.Level {
        NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    }
}
