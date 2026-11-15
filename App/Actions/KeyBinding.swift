import AppKit
import ConstellationCore
import SwiftUI

// KeyStroke and KeyBinding live in ConstellationCore, with keys.conf and the keymap.

extension KeyStroke {
    private static let namedKeyCodes: [UInt16: String] = [
        123: "left", 124: "right", 125: "down", 126: "up",
        36: "return", 76: "return", 49: "space", 53: "escape", 48: "tab", 51: "delete",
    ]

    /// The number row by key code, so ⌘⇧1 reads as shift+1 rather than "!".
    private static let digitKeyCodes: [UInt16: String] = [
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
    ]

    init?(_ event: NSEvent) {
        let flags = event.modifierFlags
        var modifiers: Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if let named = Self.namedKeyCodes[event.keyCode] {
            self.init(key: named, modifiers: modifiers)
            return
        }
        if !modifiers.isDisjoint(with: [.command, .option, .control]), let digit = Self.digitKeyCodes[event.keyCode] {
            self.init(key: digit, modifiers: modifiers)
            return
        }
        guard let characters = event.charactersIgnoringModifiers, characters.count == 1, let character = characters.first else { return nil }
        if !character.isLetter { modifiers.remove(.shift) }
        self.init(key: character.lowercased(), modifiers: modifiers)
    }

    /// For a menu item's shortcut. Only ⌘ chords: a plain key as a menu shortcut would fire while typing.
    var keyboardShortcut: KeyboardShortcut? {
        guard modifiers.contains(.command) else { return nil }
        let equivalent: KeyEquivalent? = switch key {
        case "return": .return
        case "escape": .escape
        case "space": .space
        case "tab": .tab
        case "delete": .delete
        case "left": .leftArrow
        case "right": .rightArrow
        case "up": .upArrow
        case "down": .downArrow
        default: key.count == 1 ? KeyEquivalent(Character(key)) : nil
        }
        guard let equivalent else { return nil }
        var flags: EventModifiers = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        return KeyboardShortcut(equivalent, modifiers: flags)
    }
}
