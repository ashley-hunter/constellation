import AppKit
import ConstellationCore
import SwiftUI

/// The chat box for one session, as Sort's AI Chat Composer: a rounded field with a ghost "+" for
/// files, the text, the model and effort as one quiet label, dictation and a send button, which
/// stops the turn while one runs and nothing is typed. It grows into two rows, text over buttons,
/// once the text wraps. In the session view (`panel`) and the draft panel
/// (`draft`) a quiet row under it holds permission and the steer hint; inline on a focused
/// tile (`inline`) it's just the field. ↵ sends, or queues while a turn runs; ⌘↵ steers; ⇧↵ adds a
/// line. Files can be pasted, dropped or picked with the "+". Features plug in through
/// `ComposerAddOns`.
struct ChatComposer: View {
    enum Style { case panel, inline, draft }

    @Environment(AppModel.self) private var model
    let session: Session
    var style: Style = .panel
    var focusOnAppear = false
    @FocusState private var isFocused: Bool
    @State private var isDropTargeted = false
    @State private var scrollFade = ScrollFade()
    /// The answer ↵ gives to a question the agent asked, while nothing is typed.
    @State private var answerIndex = 0
    @State private var secretValue = ""
    @State private var savesSecret = true

    var body: some View {
        let context = ComposerContext(model: model, session: session, style: style)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(ComposerAddOns.all.enumerated()), id: \.offset) { _, addOn in
                addOn.menu(context)
            }
            if !draft.attachments.isEmpty {
                AttachmentRow(attachments: draft.attachments, size: style == .inline ? 32 : 56) { attachment in
                    model.removeAttachment(attachment.id, from: session.id)
                }
            }
            pill(context)
            if style != .inline {
                quietRow(context)
                QueueStrip(session: session)
            }
        }
        .onDrop(of: AppModel.droppableTypes, isTargeted: $isDropTargeted) { providers in
            model.acceptDrop(providers, onto: session.id, onTile: false)
        }
        .task {
            guard focusOnAppear || model.composerFocusRequest == session.id else { return }
            await takeFocus()
        }
        .onChange(of: model.composerFocusRequest) { _, id in
            guard id == session.id else { return }
            Task { await takeFocus() }
        }
        .onChange(of: isFocused) { _, focused in
            if focused {
                model.activeComposerID = session.id
            } else if model.activeComposerID == session.id {
                model.activeComposerID = nil
            }
        }
        .onDisappear { if model.activeComposerID == session.id { model.activeComposerID = nil } }
        .onChange(of: session.nextAsk?.id) {
            answerIndex = 0
            secretValue = ""
        }
    }

    // MARK: Answering in the reply box

    /// The ask the reply box answers: in the session view and draft panel, not inline on a tile,
    /// which has its own answers.
    private var pendingAsk: Ask? { style == .inline ? nil : session.nextAsk }

    /// A question with a few answers: the reply box lists them over the text, like a menu.
    private var questionAnswers: (ask: Ask, question: QuestionAsk.Question)? {
        guard let ask = pendingAsk, case .question(let question) = ask.kind, !ask.choices.isEmpty,
              let first = question.questions.first else { return nil }
        return (ask, first)
    }

    private var pendingSecret: SecretAsk? {
        if case .secret(let secret) = pendingAsk?.kind { secret } else { nil }
    }

    private func answerList(_ ask: Ask, _ question: QuestionAsk.Question) -> some View {
        let isChoosing = draft.isEmpty
        return VStack(spacing: 1) {
            ForEach(Array(ask.choices.enumerated()), id: \.offset) { index, choice in
                let isSelected = isChoosing && index == answerIndex
                Button { model.answer(ask: ask, with: choice.answer) } label: {
                    // The description on its own line under the answer, so a long one wraps rather than
                    // being cut off beside it.
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(index + 1)").font(.ui(12)).foregroundStyle(Palette.textTertiary).frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(choice.label).font(.ui(13)).foregroundStyle(Palette.text).lineLimit(1)
                            if let description = question.options[index].description, !description.isEmpty {
                                Text(description).font(.ui(12)).foregroundStyle(Palette.textSecondary).lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 8)
                        if isSelected { KeyChip("↵") }
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .frame(minHeight: 30)
                    .background(isSelected ? Palette.rowSelected : .clear, in: .rect(cornerRadius: 7))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .onContinuousHover { phase in
                    if case .active = phase { answerIndex = index }
                }
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(5)
    }

    private func provideSecret() {
        guard let ask = pendingAsk, !secretValue.isEmpty else { return }
        model.answer(ask: ask, with: .secret(value: secretValue, saveForProject: savesSecret))
        secretValue = ""
    }

    private var draft: ChatDraft { model.chatDraft(for: session.id) }

    private func takeFocus() async {
        if model.composerFocusRequest == session.id { model.composerFocusRequest = nil }
        isFocused = true
        // Focusing a field selects its text; put the caret after what was already typed instead.
        try? await Task.sleep(for: .milliseconds(50))
        NSApp.sendAction(#selector(NSResponder.moveToEndOfDocument(_:)), to: nil, from: nil)
    }

    private var text: Binding<String> {
        Binding(
            get: { model.chatDraft(for: session.id).text },
            set: { newValue in model.updateDraft(session.id) { $0.text = newValue } }
        )
    }

    private func pill(_ context: ComposerContext) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return VStack(spacing: 0) {
            if let (ask, question) = questionAnswers {
                answerList(ask, question)
                Rectangle().fill(Palette.hairline).frame(height: 1)
            }
            pillRow(context)
        }
        .background(Palette.composer, in: shape)
        .overlay {
            shape.inset(by: -0.5)
                .stroke(isDropTargeted ? Palette.ask.opacity(0.7) : Palette.text.opacity(isFocused ? 0.22 : 0.15), lineWidth: 1)
                .allowsHitTesting(false)
        }
        // Sort's two faint shadows, a little stronger to read on the dark glass.
        .shadow(color: .black.opacity(0.08), radius: 5)
        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
        .contentShape(shape)
        .onTapGesture { isFocused = true }
        .animation(.hover, value: isFocused)
    }

    private func pillRow(_ context: ComposerContext) -> some View {
        PillLayout {
            Button { model.presentAttachmentPanel(for: session.id) } label: {
                Image(systemName: "plus").font(.system(size: 14))
            }
            .buttonStyle(ComposerIconButtonStyle())
            .help("Attach files (or paste or drop them here)")
            field(context)
            HStack(spacing: 4) {
                if style == .inline {
                    if let queued = model.queues[session.id]?.count {
                        Text("\(queued) queued").font(.ui(12)).foregroundStyle(Palette.textTertiary).padding(.horizontal, 4)
                    }
                } else {
                    ModelEffortMenu(session: session)
                    Button(action: dictate) {
                        Image(systemName: "waveform").font(.system(size: 13))
                    }
                    .buttonStyle(ComposerIconButtonStyle())
                    .help("Dictate")
                }
                if pendingSecret != nil {
                    Button(action: provideSecret) {
                        Image(systemName: "arrow.up").font(.system(size: 14, weight: .semibold))
                    }
                    .buttonStyle(SendButtonStyle())
                    .disabled(secretValue.isEmpty)
                    .help("Provide (↵)")
                } else if draft.isEmpty, model.canInterrupt(session.id) {
                    Button { model.interrupt(session.id) } label: {
                        Image(systemName: "stop.fill").font(.system(size: 10))
                    }
                    .buttonStyle(SendButtonStyle())
                    .help("Interrupt (\(model.binding(for: .sessionInterrupt)?.label ?? "⌘."))")
                } else {
                    Button { send(steer: false) } label: {
                        Image(systemName: "arrow.up").font(.system(size: 14, weight: .semibold))
                    }
                    .buttonStyle(SendButtonStyle())
                    .disabled(draft.isEmpty)
                    .help(sendHelp)
                }
            }
        }
    }

    /// The text. Past eight lines it scrolls, fading out at whichever edge has more beyond it.
    @ViewBuilder private func field(_ context: ComposerContext) -> some View {
        if let secret = pendingSecret {
            // The box itself takes the secret, hidden, so it never sits in the chat.
            HStack(spacing: 8) {
                Image(systemName: "lock").font(.system(size: 12)).foregroundStyle(Palette.textTertiary)
                SecureField("Paste \(secret.name)", text: $secretValue)
                    .textFieldStyle(.plain)
                    .font(.ui(14))
                    .focused($isFocused)
                    .onSubmit(provideSecret)
            }
        } else {
            textField(context)
        }
    }

    @ViewBuilder private func textField(_ context: ComposerContext) -> some View {
        let input = TextField(placeholder, text: text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.ui(14))
            .lineSpacing(3)
            .focused($isFocused)
            .onKeyPress(phases: .down) { press in handleKey(press, context) }
        if style == .inline {
            input.lineLimit(1...3)
        } else {
            input
                .lineLimit(1...8)
                .background { FieldScrollReader(isFocused: isFocused, fade: $scrollFade) }
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: scrollFade.top ? 24 : 0)
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: scrollFade.bottom ? 24 : 0)
                    }
                    .animation(.hover, value: scrollFade)
                }
        }
    }

    /// Permission, what ↵ does while a turn runs, and Steer when it can.
    private func quietRow(_ context: ComposerContext) -> some View {
        HStack(spacing: 8) {
            if pendingSecret != nil, let ask = pendingAsk {
                Toggle("Save for this project", isOn: $savesSecret)
                    .toggleStyle(.checkbox)
                    .font(.ui(12))
                    .foregroundStyle(Palette.textSecondary)
                Spacer(minLength: 4)
                Button("Decline") { model.answer(ask: ask, with: .secretDeclined) }
                    .buttonStyle(ConstellationButtonStyle(weight: .quiet, height: 26))
            } else {
                quietRowContent(context)
            }
        }
    }

    @ViewBuilder private func quietRowContent(_ context: ComposerContext) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(ComposerAddOns.all.enumerated()), id: \.offset) { _, addOn in
                addOn.toolbar(context)
            }
            if let hint {
                Text(hint)
                    .font(.ui(12))
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            if route(steer: true) == .steer {
                Button { send(steer: true) } label: { KeyedLabel("Steer", key: "⌘↵") }
                    .buttonStyle(ConstellationButtonStyle(weight: .quiet, height: 26))
                    .disabled(draft.isEmpty)
            }
        }
    }

    private func handleKey(_ press: KeyPress, _ context: ComposerContext) -> KeyPress.Result {
        // With nothing typed, ↑ ↓ choose among a question's answers and ↵ gives it.
        // Arrow keys come flagged as numeric pad and function keys, which aren't held modifiers.
        if draft.isEmpty, press.modifiers.subtracting([.numericPad, .function]).isEmpty, let ask = questionAnswers?.ask {
            let choices = ask.choices
            switch press.key {
            case .upArrow:
                answerIndex = (answerIndex - 1 + choices.count) % choices.count
                return .handled
            case .downArrow:
                answerIndex = (answerIndex + 1) % choices.count
                return .handled
            case .return:
                model.answer(ask: ask, with: choices[min(answerIndex, choices.count - 1)].answer)
                return .handled
            default: break
            }
        }
        for addOn in ComposerAddOns.all where addOn.handleKey(press, context) == .handled {
            return .handled
        }
        guard press.key == .return else { return .ignored }
        // ⇧↵ and ⌥↵ start a new line. Left to the field, ⇧↵ ends editing instead, which selects
        // everything typed so the next key replaces it.
        if press.modifiers.contains(.shift) || press.modifiers.contains(.option) {
            NSApp.sendAction(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), to: nil, from: nil)
            return .handled
        }
        send(steer: press.modifiers.contains(.command))
        return .handled
    }

    /// Sort's dictate button, done by macOS: its own dictation, into this field.
    private func dictate() {
        isFocused = true
        DispatchQueue.main.async { NSApp.sendAction(Selector(("startDictation:")), to: nil, from: nil) }
    }

    private func send(steer: Bool) {
        model.sendDraft(session.id, steer: steer)
        if style == .inline { model.closeInlineComposer() }
    }

    private func route(steer: Bool) -> SendRoute {
        session.sendRoute(steer: steer)
    }

    private var placeholder: String {
        if session.isDraft {
            return "What should the agent do?"
        }
        return switch route(steer: false) {
        case .answerAsk:
            switch session.nextAsk?.kind {
            case .permission: "Or reply instead"
            case .question(let question) where question.questions.count == 1: "Or type your own answer"
            default: "Reply to \(session.title)"
            }
        case .queue: "Queue a message for when this turn ends"
        case .steer, .startTurn: "Message \(session.title)"
        }
    }

    private var sendHelp: String {
        if session.isDraft { return "Start (↵)" }
        return switch route(steer: false) {
        case .answerAsk: "Reply (↵)"
        case .queue: "Queue for when this turn ends (↵)"
        case .steer, .startTurn: "Send (↵)"
        }
    }

    private var hint: String? {
        if let ask = session.nextAsk {
            // The placeholder says what typing does for these.
            if case .question(let question) = ask.kind, question.questions.count == 1 { return nil }
            if case .secret = ask.kind { return "A reply declines the secret and sends your message." }
            if case .question = ask.kind, session.provider == .codex { return "A reply answers each question with your message." }
            if case .question = ask.kind { return "Replying skips these questions and sends your message instead." }
            return "Replying skips this step and sends your message instead."
        }
        switch route(steer: false) {
        case .queue where route(steer: true) == .steer: return "↵ queues for the end of this turn, ⌘↵ steers it now."
        case .queue: return "↵ queues until the session is running."
        default: return nil
        }
    }
}

/// Which edges of the scrolled text have more beyond them.
private struct ScrollFade: Equatable {
    var top = false
    var bottom = false
}

/// Reads how far the field has scrolled. SwiftUI doesn't say, so while the field has focus this
/// watches the clip view AppKit scrolls its editor in. Unfocused, the field shows its first lines,
/// so only the bottom can have more.
private struct FieldScrollReader: NSViewRepresentable {
    let isFocused: Bool
    @Binding var fade: ScrollFade

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.fade = $fade
        let isFocused = isFocused
        DispatchQueue.main.async { context.coordinator.watch(isFocused ? Self.editor(over: view) : nil) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// The window's field editor, if it's editing the field this view sits behind.
    private static func editor(over view: NSView) -> NSTextView? {
        guard let editor = view.window?.firstResponder as? NSTextView, editor.isFieldEditor || editor.superview is NSClipView else { return nil }
        let field = view.convert(view.bounds, to: nil)
        return field.intersects(editor.convert(editor.visibleRect, to: nil)) ? editor : nil
    }

    @MainActor
    final class Coordinator {
        var fade: Binding<ScrollFade>?
        private weak var editor: NSTextView?
        private var observers: [NSObjectProtocol] = []
        private var overflows = false

        func watch(_ editor: NSTextView?) {
            guard editor !== self.editor || editor == nil else { return }
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            self.editor = editor
            guard let editor, let clip = editor.superview as? NSClipView else {
                set(ScrollFade(top: false, bottom: overflows))
                return
            }
            clip.postsBoundsChangedNotifications = true
            editor.postsFrameChangedNotifications = true
            for (name, object) in [(NSView.boundsDidChangeNotification, clip as NSView), (NSView.frameDidChangeNotification, editor)] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.measure() }
                })
            }
            measure()
        }

        private func measure() {
            guard let editor, let clip = editor.superview as? NSClipView else { return }
            let visible = clip.bounds
            overflows = editor.frame.height > visible.height + 1
            set(ScrollFade(top: visible.minY > 1, bottom: visible.maxY < editor.frame.height - 1))
        }

        private func set(_ value: ScrollFade) {
            if fade?.wrappedValue != value { fade?.wrappedValue = value }
        }
    }
}

enum ComposerMetrics {
    /// The field's 12 pt corner less the 6 pt it insets its buttons, so they sit concentric.
    static let buttonRadius: CGFloat = 6
}

/// The composer's layout: one 40 pt row of "+", text and the trailing controls, or, once the text
/// would wrap in that row, the text across the top with the buttons in a row beneath. It decides
/// from the one-row width alone, so it can't flip back and forth, and keeps the text field's
/// identity either way, so focus and the caret survive the switch. Subviews: leading, text,
/// trailing.
private struct PillLayout: Layout {
    static let rowHeight: CGFloat = 40
    /// Sort's paddings: 6 around the buttons, 8 beside the text in a row, 12 by 10 round it above them.
    private let inset: CGFloat = 6
    private let textGap: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 480
        guard subviews.count == 3 else { return CGSize(width: width, height: Self.rowHeight) }
        if let textHeight = columnTextHeight(width: width, subviews: subviews) {
            return CGSize(width: width, height: 10 + textHeight + 10 + Self.rowHeight)
        }
        return CGSize(width: width, height: Self.rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let (leading, text, trailing) = (subviews[0], subviews[1], subviews[2])
        let buttonsY = bounds.maxY - Self.rowHeight / 2
        leading.place(at: CGPoint(x: bounds.minX + inset, y: buttonsY), anchor: .leading, proposal: .unspecified)
        trailing.place(at: CGPoint(x: bounds.maxX - inset, y: buttonsY), anchor: .trailing, proposal: .unspecified)
        if let textHeight = columnTextHeight(width: bounds.width, subviews: subviews) {
            text.place(at: CGPoint(x: bounds.minX + 12, y: bounds.minY + 10), proposal: ProposedViewSize(width: bounds.width - 24, height: textHeight))
        } else {
            text.place(
                at: CGPoint(x: bounds.minX + rowTextX(subviews), y: bounds.midY),
                anchor: .leading,
                proposal: ProposedViewSize(width: rowTextWidth(bounds.width, subviews: subviews), height: nil)
            )
        }
    }

    private func rowTextX(_ subviews: Subviews) -> CGFloat {
        inset + subviews[0].sizeThatFits(.unspecified).width + textGap
    }

    private func rowTextWidth(_ width: CGFloat, subviews: Subviews) -> CGFloat {
        max(40, width - rowTextX(subviews) - textGap - subviews[2].sizeThatFits(.unspecified).width - inset)
    }

    /// The text's height across the top, or nil while it fits on the one row.
    private func columnTextHeight(width: CGFloat, subviews: Subviews) -> CGFloat? {
        let text = subviews[1]
        let oneRow = text.sizeThatFits(ProposedViewSize(width: rowTextWidth(width, subviews: subviews), height: nil)).height
        guard oneRow > 24 else { return nil }
        return text.sizeThatFits(ProposedViewSize(width: width - 24, height: nil)).height
    }
}

/// The composer's ghost buttons: a 28 pt square concentric with the field (12 less the 6 inset),
/// muted until hovered.
private struct ComposerIconButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isHovered ? Palette.text : Palette.textSecondary)
            .frame(width: 28, height: 28)
            .background(isHovered || configuration.isPressed ? Palette.text.opacity(0.1) : .clear, in: .rect(cornerRadius: ComposerMetrics.buttonRadius, style: .continuous))
            .contentShape(.rect)
            .onHover { isHovered = $0 }
            .animation(.hover, value: isHovered)
    }
}

/// Send: a 28 pt rounded square in the text colour with a dark arrow, a 40% inner edge and a small
/// shadow; the muted colour at half strength while there's nothing to send.
private struct SendButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: ComposerMetrics.buttonRadius, style: .continuous)
        configuration.label
            .foregroundStyle(Palette.surfaceSunken)
            .frame(width: 28, height: 28)
            .background(isEnabled ? (configuration.isPressed ? Palette.text.opacity(0.85) : Palette.text) : Palette.textSecondary, in: shape)
            .opacity(isEnabled ? 1 : 0.5)
            .overlay(shape.strokeBorder(.white.opacity(isEnabled ? 0.4 : 0), lineWidth: 1))
            .shadow(color: .black.opacity(isEnabled ? 0.3 : 0), radius: 1.5, y: 3)
            .contentShape(shape)
            .animation(.hover, value: isEnabled)
    }
}
