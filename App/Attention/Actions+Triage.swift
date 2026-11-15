import ConstellationCore

/// Triage, and skipping about in it.
extension ActionRegistry {
    static var triageActions: [PaletteAction] {
        [
            PaletteAction(
                id: .triage, title: "Triage", keywords: ["next", "needs you", "waiting", "ask", "failed", "unseen", "work through", "inbox", "caught up"],
                systemImage: "tray.full", section: .command,
                // ⌥Tab was "Next that needs you"; triage opens it and carries on to the rest.
                keys: [KeyBinding("alt+tab")],
                perform: { context, _ in context.model.startTriage() }
            ),
            PaletteAction(
                id: .triageNext, title: "Skip to the next that needs you", section: .navigation,
                keys: [KeyBinding("cmd+]")],
                isAvailable: { context, _ in context.model.isTriaging },
                perform: { context, _ in context.model.stepTriage(by: 1) }
            ),
            PaletteAction(
                id: .triagePrevious, title: "Back to the one before in triage", section: .navigation,
                keys: [KeyBinding("cmd+[")],
                isAvailable: { context, _ in context.model.isTriaging && (context.model.triage?.index ?? 0) > 0 },
                perform: { context, _ in context.model.stepTriage(by: -1) }
            ),
        ]
    }
}

extension AppModel {
    /// Triage's session is the one open.
    var isTriaging: Bool {
        triage?.current != nil && triage?.current == openedSessionID
    }
}

extension ActionID {
    static let triage: ActionID = "triage"
    static let triageNext: ActionID = "triage.next"
    static let triagePrevious: ActionID = "triage.previous"
}
