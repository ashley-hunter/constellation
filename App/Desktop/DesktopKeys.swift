import AppKit
import ConstellationCore

/// Keys on the desktop window. Every key runs a registered action (see PaletteAction.swift); the
/// rest are typing, which goes to a composer.
enum DesktopKeys {
    static func isPaste(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command
            && event.charactersIgnoringModifiers?.lowercased() == "v"
    }

    /// The text a key types, when it is printable and has no ⌘, ⌃ or ⌥.
    static func typedText(_ event: NSEvent) -> String? {
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
              let characters = event.characters, !characters.isEmpty,
              characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value) })
        else { return nil }
        return characters
    }
}

extension AppModel {
    /// Runs the first available action bound to the key, through the keymap from keys.conf. Returns
    /// false when none ran, so the key goes on to the text field or becomes typing. Only ⌘ chords,
    /// esc and tab reach here while a text field is editing.
    func handleKey(_ stroke: KeyStroke, isEditingText: Bool, inShell: Bool, shellKeepsEscape: Bool = true) -> Bool {
        if commandSpreadPile != nil, keyboard.showsDigitHints { commandSpreadUsed = true }
        if let onboarding { return onboarding.handle(stroke, inShell: inShell) }
        if keyboard.hintSession != nil { return handleHintKey(stroke) }
        if isEditingText, answersPermission(stroke) || togglesDraftWorktree(stroke) { return true }
        if isEditingText, !stroke.worksWhileEditing { return false }
        // The shell keeps tab for completion (⌥Tab still reaches triage), and esc while a command
        // runs, for vim, less and the like. At its prompt esc goes back, closing the window; ⌘W
        // closes the shell.
        if inShell, (stroke.key == "tab" && stroke.modifiers.isSubset(of: .shift)) || (stroke == KeyStroke(key: "escape") && shellKeepsEscape) { return false }
        if stroke.modifiers.isEmpty, let menuKey = ComposerMenuKey(stroke.key), handleComposerMenuKey(menuKey) { return true }
        if keyboard.isSequencePending, stroke == KeyStroke(key: "escape") {
            keyboard.cancelSequence()
            return true
        }
        switch surface {
        case .attachment, .sheet, .terminal:
            // Over a zoomed image, a sheet or an opened terminal, only single keys: no sequences.
            guard case .exact(let entries) = keyboard.keymap.match([stroke]) else { return false }
            return runKeyEntries(entries)
        default:
            return keyboard.feed(stroke) { [weak self] entries in self?.runKeyEntries(entries) ?? false }
        }
    }

    /// A permission's ⌥ answer keys act even while the reply box has the keys, as its buttons show
    /// them there. ⌥Y and the like type little worth losing; a question's ⌥ digits stay typing.
    private func answersPermission(_ stroke: KeyStroke) -> Bool {
        guard stroke.modifiers.contains(.option), let id = openedSessionID ?? activeComposerID,
              let ask = sessionsByID[id]?.nextAsk, case .permission = ask.kind,
              case .exact(let entries) = keyboard.keymap.match([stroke]),
              let key = entries.first(where: { $0.rule.action == ActionID.askAnswer.rawValue })?.rule.argument,
              let choice = ask.choices.first(where: { $0.key == key }) else { return false }
        answer(ask: ask, with: choice.answer)
        return true
    }

    /// ⌥W moves an open draft between a new worktree and the project folder, even while its text
    /// field has the keys.
    private func togglesDraftWorktree(_ stroke: KeyStroke) -> Bool {
        guard stroke.modifiers.contains(.option), case .exact(let entries) = keyboard.keymap.match([stroke]),
              entries.contains(where: { $0.rule.action == ActionID.draftWorktree.rawValue }) else { return false }
        return perform(.draftWorktree, via: .key)
    }

    private func runKeyEntries(_ entries: [Keymap.Entry]) -> Bool {
        for entry in entries {
            let id = ActionID(rawValue: entry.rule.action)
            if keyReaches(id), perform(id, argument: entry.rule.argument, via: .key) { return true }
        }
        return false
    }

    /// Which keys reach past what is in front (see `surface`). Over a zoomed image only esc acts;
    /// over a sheet only esc (and ⌘K, to close the palette); over an opened terminal, esc, new
    /// session, ⌘W, maximise and moving on to what needs you, which closes the terminal. Over the
    /// session view, a draft or the grid, its own keys act but the desktop behind keeps still:
    /// nothing moves focus, jumps to a tile or opens one until it closes.
    private func keyReaches(_ id: ActionID) -> Bool {
        switch surface {
        case .attachment: id == .back
        case .sheet(.palette), .sheet(.projects): id == .back || id == .palette
        case .sheet: id == .back
        case .terminal: Self.overTerminal.contains(id)
        case .grid, .session: !Self.desktopNavigation.contains(id)
        case .onboarding, .launcher, .inlineComposer, .desktop: true
        }
    }

    static let overTerminal: Set<ActionID> = [
        .back, .sessionNew, .tileClose, .panelMaximise,
        .triage, .triageNext, .triagePrevious, .focusNextBlocked,
    ]

    /// Keys that move around the desktop's tiles, which an open panel holds still.
    static let desktopNavigation: Set<ActionID> = [
        .focusMove, .focusPreviousBlocked,
        .tileFocus, .tileOpen, .tileSplit, .hintsShow,
        .stackNext, .stackPrevious,
    ]

    /// Something covers the desktop: a sheet, an opened session, draft, terminal or the grid, or a
    /// zoomed attachment. Its tiles take no keys or focus until it goes.
    var isDesktopCovered: Bool {
        surface.coversDesktop
    }

    /// A printable key, when no tile key used it and no text field has focus, goes to what is in
    /// front: the launcher's filter, the open session view's composer, or on the desktop a full
    /// tile's inline one, or for a smaller tile the session view, which opens for it.
    func startTyping(_ text: String) -> Bool {
        let surface = surface
        if surface == .launcher {
            launcher.query += text
            return true
        }
        if let id = surface.sessionID {
            guard sessionsByID[id]?.lifecycle != .archived else { return false }
            updateDraft(id) { $0.text += text }
            composerFocusRequest = id
            return true
        }
        guard surface == .desktop, case .session(let id)? = focusedItem, let session = sessionsByID[id],
              session.lifecycle != .archived else { return false }
        if session.isDraft {
            updateDraft(id) { $0.text += text }
            openSession(id)
            composerFocusRequest = id
            return true
        }
        if LifecycleRules.presentation(of: session) == .full, visibleSessions.contains(where: { $0.id == id }) {
            openInlineComposer(id, typing: text)
        } else {
            updateDraft(id) { $0.text += text }
            openSession(id)
            composerFocusRequest = id
        }
        return true
    }

    /// The ring of tiles in the focused tile's stack, when it is in one.
    var focusedStack: [TileItem]? {
        focusedItem.flatMap { geometry.stack(containing: $0) }
    }

    /// Turns the focused tile's stack one card forward (the front goes to the back) or back.
    func cycleStack(by step: Int) {
        guard let current = focusedItem, let ring = focusedStack, let index = ring.firstIndex(of: current) else { return }
        focusedItem = ring[(index + step + ring.count) % ring.count]
    }
}
