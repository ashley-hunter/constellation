import ConstellationCore
import SwiftUI

/// Queued messages as chips under the composer. Each can be edited, moved, removed, or sent now as
/// a steer.
struct QueueStrip: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        let queue = model.queues[session.id] ?? []
        if !queue.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Queued · sent in order when this turn ends")
                    .font(.ui(11))
                    .foregroundStyle(Palette.textTertiary)
                ForEach(Array(queue.enumerated()), id: \.element.id) { index, queued in
                    QueueChip(session: session, queued: queued, isFirst: index == 0, isLast: index == queue.count - 1)
                }
            }
        }
    }
}

private struct QueueChip: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let queued: QueuedMessage
    let isFirst: Bool
    let isLast: Bool
    @State private var editing: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock").font(.system(size: 10)).foregroundStyle(Palette.textTertiary)
            if let editing {
                TextField("Message", text: Binding(get: { editing }, set: { self.editing = $0 }), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.ui(12))
                    .lineLimit(1...4)
                    .focused($isFocused)
                    .onSubmit(save)
                    .onKeyPress(.escape) {
                        self.editing = nil
                        return .handled
                    }
                    .onAppear { isFocused = true }
                icon("checkmark", help: "Save", action: save)
            } else {
                Text(label)
                    .font(.ui(12))
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onTapGesture(count: 2) { editing = queued.message.text }
                icon("pencil", help: "Edit") { editing = queued.message.text }
                icon("chevron.up", help: "Move up", disabled: isFirst) { model.moveQueued(queued.id, in: session.id, by: -1) }
                icon("chevron.down", help: "Move down", disabled: isLast) { model.moveQueued(queued.id, in: session.id, by: 1) }
                icon("arrow.turn.down.right", help: "Steer now: send to the running turn", disabled: session.sendRoute(steer: true) == .queue) {
                    model.steerQueued(queued.id, in: session.id)
                }
                icon("xmark", help: "Remove") { model.removeQueued(queued.id, in: session.id) }
            }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 26)
        .background(Palette.surfaceRaised.opacity(0.6), in: .rect(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.text.opacity(0.1)))
    }

    private var label: String {
        let text = queued.message.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let attachments = queued.message.attachments
        guard !attachments.isEmpty else { return text }
        return (text.isEmpty ? "" : text + " ") + LiveOutput.attachmentLabel(attachments)
    }

    private func save() {
        guard let editing else { return }
        model.editQueued(queued.id, in: session.id, text: editing)
        self.editing = nil
    }

    private func icon(_ name: String, help: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 10, weight: .semibold))
        }
        .buttonStyle(IconButtonStyle(width: 20, height: 20))
        .disabled(disabled)
        .help(help)
    }
}
