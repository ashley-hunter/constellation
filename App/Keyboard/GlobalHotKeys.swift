import Carbon.HIToolbox
import ConstellationCore

/// Hotkeys that work while another app is in front, registered with Carbon's `RegisterEventHotKey`,
/// which needs no Accessibility permission.
@MainActor
final class GlobalHotKeys {
    var onPress: ((KeyRule) -> Void)?
    private var registered: [UInt32: (rule: KeyRule, ref: EventHotKeyRef)] = [:]
    private var current: [KeyRule]?
    private var handler: EventHandlerRef?
    private static let signature: OSType = 0x434E_5354 // "CNST"

    /// Replaces the registered hotkeys. Keys Carbon can't take, or another app holds, are skipped.
    func register(_ entries: [Keymap.Entry]) {
        let rules = entries.map(\.rule)
        guard rules != current else { return }
        current = rules
        unregisterAll()
        installHandlerIfNeeded()
        for (index, rule) in rules.enumerated() {
            guard rule.strokes.count == 1, let stroke = rule.strokes.first, let code = Self.keyCode(for: stroke.key) else { continue }
            let id = UInt32(index + 1)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                code, Self.carbonModifiers(stroke.modifiers), EventHotKeyID(signature: Self.signature, id: id),
                GetApplicationEventTarget(), 0, &ref
            )
            if status == noErr, let ref {
                registered[id] = (rule, ref)
            } else {
                Log.app.notice("Global hotkey \(stroke.label, privacy: .public) not registered: \(status)")
            }
        }
    }

    private func unregisterAll() {
        for (_, entry) in registered { UnregisterEventHotKey(entry.ref) }
        registered = [:]
    }

    private func pressed(_ id: UInt32) {
        guard let rule = registered[id]?.rule else { return }
        onPress?(rule)
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var hotKey = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &hotKey
            )
            guard status == noErr, hotKey.signature == GlobalHotKeys.signature else { return OSStatus(eventNotHandledErr) }
            let id = hotKey.id
            // Carbon delivers application events on the main thread.
            MainActor.assumeIsolated {
                Unmanaged<GlobalHotKeys>.fromOpaque(context).takeUnretainedValue().pressed(id)
            }
            return noErr
        }, 1, &type, context, &handler)
    }

    private static func carbonModifiers(_ modifiers: KeyStroke.Modifiers) -> UInt32 {
        var flags = 0
        if modifiers.contains(.command) { flags |= cmdKey }
        if modifiers.contains(.option) { flags |= optionKey }
        if modifiers.contains(.control) { flags |= controlKey }
        if modifiers.contains(.shift) { flags |= shiftKey }
        return UInt32(flags)
    }

    /// ANSI key codes for the keys keys.conf can name.
    static func keyCode(for key: String) -> UInt32? {
        let codes: [String: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
            "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
            "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
            "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
            "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
            "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
            "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
            ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period,
            "/": kVK_ANSI_Slash, "\\": kVK_ANSI_Backslash, "`": kVK_ANSI_Grave,
            "space": kVK_Space, "return": kVK_Return, "tab": kVK_Tab, "escape": kVK_Escape, "delete": kVK_Delete,
            "left": kVK_LeftArrow, "right": kVK_RightArrow, "up": kVK_UpArrow, "down": kVK_DownArrow,
        ]
        return codes[key].map(UInt32.init)
    }
}
