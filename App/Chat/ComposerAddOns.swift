import ConstellationCore
import SwiftUI

/// What a composer add-on sees: the session, its draft, and how to change the draft.
@MainActor
struct ComposerContext {
    let model: AppModel
    let session: Session
    let style: ChatComposer.Style

    var draft: ChatDraft { model.chatDraft(for: session.id) }

    func update(_ change: (inout ChatDraft) -> Void) {
        model.updateDraft(session.id, change)
    }

    /// Replaces the whole text, e.g. a history entry or a completed `/command`.
    func setText(_ text: String) {
        update { $0.text = text }
    }
}

/// A feature that plugs into every chat composer, in the session view and inline on tiles.
///
/// Planned add-ons: model, effort, fast and permission pickers (`toolbar`), the
/// `/` command menu and `@` file picker (`menu` and `handleKey`), and prompt history (`handleKey`).
/// Add a type conforming to this and list it in `ComposerAddOns.all`.
@MainActor
protocol ComposerAddOn {
    /// Controls in the quiet row under the composer. Nil to add nothing.
    func toolbar(_ context: ComposerContext) -> AnyView?
    /// A menu floating above the text field, e.g. while the text starts with `/`. Nil when closed.
    func menu(_ context: ComposerContext) -> AnyView?
    /// Keys reach add-ons, in order, before the composer's own ↵ and ⌘↵. Return `.handled` to
    /// stop them there (↑ ↓ in an open menu, ↑ for history in an empty composer).
    func handleKey(_ press: KeyPress, _ context: ComposerContext) -> KeyPress.Result
}

extension ComposerAddOn {
    func toolbar(_ context: ComposerContext) -> AnyView? { nil }
    func menu(_ context: ComposerContext) -> AnyView? { nil }
    func handleKey(_ press: KeyPress, _ context: ComposerContext) -> KeyPress.Result { .ignored }
}

@MainActor
enum ComposerAddOns {
    static let all: [any ComposerAddOn] = [TurnSettingsAddOn(), CompletionMenuAddOn(), PromptHistoryAddOn()]
}
