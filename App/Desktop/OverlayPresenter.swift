import AppKit
import SwiftUI

/// One overlay slot over the desktop: a scrim that only fades and the item's panel, opened and
/// closed by a spring on a progress value rather than by an insertion transition. The panel stays
/// mounted while it closes, so asking for the same item again turns the spring around from wherever
/// it is, with no jump and no fresh view. A different item takes the slot with a crossfade.
///
/// Content is laid out in the whole container, so a hero's rects (in the container's points) say
/// exactly where the panel is.
struct OverlayPresenter<Item: Hashable, Content: View>: View {
    /// What the model wants shown; nil to close.
    let item: Item?
    /// Whether the item dims the desktop behind it.
    var dims: (Item) -> Bool = { _ in true }
    /// A click on the scrim.
    let dismiss: () -> Void
    var style: (Item) -> PresentationStyle = { _ in .popin }
    /// What a hero grows out of, crossfaded into the panel (see `PresentationEffect`).
    var standIn: (Item) -> AnyView? = { _ in nil }
    /// Called as an item starts opening, after `closed` for one it replaces.
    var presented: (Item) -> Void = { _ in }
    /// Called once an item has finished closing, or been replaced by another, and wasn't reopened.
    var closed: (Item) -> Void = { _ in }
    @ViewBuilder let content: (Item) -> Content

    /// The item on screen, kept until its close finishes.
    @State private var shown: Item?
    @State private var progress = 0.0
    /// How the shown item comes and goes, taken as it opens and again as it starts closing rather
    /// than read afresh every frame, so a card moving behind the panel can't make it jump. A hero
    /// follows its card on the same spring when the card moves (see `follow`).
    @State private var shownStyle = PresentationStyle.popin
    /// Bumped by every open and close, so a close that was turned around never unmounts.
    @State private var generation = 0
    /// Open and done moving, for content that can't move with the panel.
    @State private var isSettled = false
    /// The text field or shell that had the keys when the panel closed, for a reopen to hand them back.
    @State private var keys = KeyHolder()

    var body: some View {
        let isOpen = item != nil
        let dimming = shown.map(dims) ?? false
        ZStack {
            // Always here, so its fade is one value the same spring moves.
            Color.black.opacity(dimming ? 0.45 * min(max(progress, 0), 1) : 0)
                .ignoresSafeArea()
                .contentShape(.rect)
                .onTapGesture(perform: dismiss)
                // Clear when it doesn't dim (a draft over the launcher), but a click outside still closes.
                .allowsHitTesting(isOpen)
            ZStack {
                if let shown {
                    content(shown)
                        .id(shown)
                        .environment(\.presentationIsSettled, isSettled)
                        // Only seen when one item replaces another: opening and closing move the
                        // progress instead, with no transition.
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(PresentationEffect(progress: progress, style: shownStyle, standIn: shown.flatMap(standIn)))
            .allowsHitTesting(isOpen)
        }
        .onChange(of: item, initial: true) { _, item in present(item) }
        .onChange(of: shown.map(style)) { _, style in follow(style) }
    }

    private func present(_ item: Item?) {
        generation += 1
        let generation = generation
        if let item {
            let replaced = shown.flatMap { $0 != item ? $0 : nil }
            if let replaced {
                keys.forget()
                closed(replaced)
            }
            presented(item)
            if replaced != nil {
                // One panel crossfades into the other where it stands.
                withAnimation(.fadeIn) { shown = item }
                retake(style(item), on: .present)
            } else if shown == nil {
                // Placed at its start with nothing moving, then grown on the next turn, so the
                // spring that grows it can't also carry it from where the last panel closed.
                withoutAnimation {
                    shown = item
                    shownStyle = style(item)
                    progress = 0
                }
                Task { @MainActor in
                    guard self.generation == generation else { return }
                    open(generation)
                }
                return
            } else {
                // Turned around while closing.
                keys.restore()
                retake(style(item), on: .present)
            }
            open(generation)
        } else if let closing = shown {
            isSettled = false
            keys.takeBack()
            let closingStyle = style(closing)
            if case .hero = closingStyle, case .popin = shownStyle {
                // An item that popped in and shrinks back into a card it now has (a kept draft):
                // the hero is put in place first, which at full size looks just as the popin did.
                withoutAnimation { shownStyle = closingStyle }
                Task { @MainActor in
                    guard self.generation == generation else { return }
                    close(closing, generation)
                }
                return
            }
            retake(closingStyle, on: .dismiss)
            close(closing, generation)
        }
    }

    private func open(_ generation: Int) {
        withAnimation(.present, completionCriteria: .logicallyComplete) {
            progress = 1
        } completion: {
            if self.generation == generation { isSettled = true }
        }
    }

    private func close(_ closing: Item, _ generation: Int) {
        withAnimation(.dismiss, completionCriteria: .logicallyComplete) {
            progress = 0
        } completion: {
            guard self.generation == generation else { return }
            withoutAnimation { shown = nil }
            keys.forget()
            closed(closing)
        }
    }

    /// Takes the shown item's style afresh: a hero's rects move on `animation`, anything else
    /// changes at once.
    private func retake(_ style: PresentationStyle, on animation: Animation) {
        if case .hero = style, case .hero = shownStyle {
            withAnimation(animation) { shownStyle = style }
        } else {
            withoutAnimation { shownStyle = style }
        }
    }

    /// The card a hero grows from or shrinks into moved, or the panel's frame changed: the hero
    /// follows on the spring it is moving on. A card that went away leaves the hero where it was.
    private func follow(_ style: PresentationStyle?) {
        guard shown != nil, let style, style != shownStyle, case .hero = style, case .hero = shownStyle else { return }
        withAnimation(item != nil ? .present : .dismiss) { shownStyle = style }
    }

    private func withoutAnimation(_ change: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, change)
    }
}

/// Takes the keys from a closing panel's text field or shell, so typing doesn't go into a panel
/// that is leaving, and gives them back if it's reopened before it has gone.
@MainActor
private final class KeyHolder {
    private weak var responder: NSResponder?

    func takeBack() {
        guard let window = NSApp.keyWindow, let current = window.firstResponder else { return }
        if let field = current as? NSTextView, field.isFieldEditor {
            responder = field.delegate as? NSResponder
        } else if current is NSTextView || current is ShellTerminalView || current.isInWebView {
            responder = current
        } else {
            return
        }
        window.makeFirstResponder(nil)
    }

    func restore() {
        guard let view = responder as? NSView, let window = view.window else { return }
        window.makeFirstResponder(view)
        responder = nil
    }

    func forget() {
        responder = nil
    }
}
