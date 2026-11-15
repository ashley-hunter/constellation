import ConstellationCore
import SwiftUI

/// The `/` command menu and the `@` file picker. ↑ ↓ pick a row, ↵ or tab takes it, esc closes it.
struct CompletionMenuAddOn: ComposerAddOn {
    func menu(_ context: ComposerContext) -> AnyView? {
        guard let menu = context.model.composerMenu(for: context.session) else { return nil }
        return AnyView(ComposerMenuView(session: context.session, menu: menu, style: context.style))
    }

    func handleKey(_ press: KeyPress, _ context: ComposerContext) -> KeyPress.Result {
        let (model, id) = (context.model, context.session.id)
        guard press.modifiers.subtracting([.numericPad, .function]).isEmpty, let menu = model.composerMenu(for: context.session), !menu.items.isEmpty else { return .ignored }
        switch press.key {
        case .upArrow: model.moveMenuSelection(id, in: menu, by: -1)
        case .downArrow: model.moveMenuSelection(id, in: menu, by: 1)
        case .return, .tab: model.acceptMenuItem(menu.items[model.selectedMenuIndex(for: id, in: menu)], in: menu, for: id)
        case .escape: model.dismissMenu(for: id)
        default: return .ignored
        }
        return .handled
    }
}

/// ↑ in an empty composer walks back through the project's earlier prompts; ↓ walks forward.
struct PromptHistoryAddOn: ComposerAddOn {
    func handleKey(_ press: KeyPress, _ context: ComposerContext) -> KeyPress.Result {
        guard press.modifiers.subtracting([.numericPad, .function]).isEmpty, press.key == .upArrow || press.key == .downArrow else { return .ignored }
        return context.model.walkPromptHistory(context.session.id, older: press.key == .upArrow) ? .handled : .ignored
    }
}

struct ComposerMenuView: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let menu: ComposerMenu
    let style: ChatComposer.Style

    var body: some View {
        let selected = model.selectedMenuIndex(for: session.id, in: menu)
        let rows = menu.items
        VStack(alignment: .leading, spacing: 1) {
            if menu.isLoading {
                Text(menu.token.kind == .command ? "Loading commands…" : "Loading files…")
                    .font(.ui(12))
                    .foregroundStyle(Palette.textTertiary)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
            } else if rows.isEmpty {
                Text(emptyText)
                    .font(.ui(12))
                    .foregroundStyle(Palette.textTertiary)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                row(item, isSelected: index == selected)
                    .onTapGesture { model.acceptMenuItem(item, in: menu, for: session.id) }
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surfaceRaised, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.text.opacity(0.12)))
    }

    private var emptyText: String {
        switch (menu.token.kind, session.provider) {
        case (.command, .codex): "No Codex skills found for this worktree"
        case (.command, .claudeCode): "No commands found"
        case (.mention, _): "No files in this worktree"
        }
    }

    private func row(_ item: ComposerMenuItem, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Text(item.title)
                .font(menu.token.kind == .command ? .ui(12) : .ui(12, weight: .medium))
                .foregroundStyle(Palette.text)
                .lineLimit(1)
                .layoutPriority(1)
            Text(item.detail)
                .font(.ui(12))
                .foregroundStyle(Palette.textTertiary)
                .lineLimit(1)
                .truncationMode(menu.token.kind == .mention ? .head : .tail)
            Spacer(minLength: 4)
            if let badge = item.badge, style != .inline {
                Text(badge)
                    .font(.ui(10))
                    .foregroundStyle(Palette.textTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .overlay(Capsule().strokeBorder(Palette.text.opacity(0.12)))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(isSelected ? Palette.rowCursor : .clear, in: .rect(cornerRadius: 5))
        .contentShape(.rect)
    }
}
