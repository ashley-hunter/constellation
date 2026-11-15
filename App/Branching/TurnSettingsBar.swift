import ConstellationCore
import SwiftUI

/// Permission mode and fast mode for a session's next turn, in a quiet row under the composer. The model and effort live in the composer itself, in `ModelEffortMenu`.
struct TurnSettingsBar: View {
    @Environment(AppModel.self) private var model
    let session: Session
    /// Wraps onto more rows instead of growing past the width it's offered.
    var wraps = false

    var body: some View {
        Group {
            if wraps {
                FlowLayout(spacing: 2) { controls }
            } else {
                HStack(spacing: 2) { controls }.fixedSize()
            }
        }
        .task(id: session.provider) { await model.loadModelChoices(for: session.provider) }
    }

    @ViewBuilder private var controls: some View {
        let current = model.modelChoices(for: session.provider).first { $0.id == session.model }
        permissionMenu
        if current?.supportsFastMode == true {
            toggle("Fast", systemImage: "hare", isOn: session.fastMode, help: "Fast mode: Codex's priority tier, for the next turn on") {
                $0.fastMode.toggle()
            }
        }
    }

    private var permissionMenu: some View {
        Menu {
            ForEach(PermissionMode.allCases, id: \.self) { mode in
                Button { change { $0.permissionMode = mode } } label: {
                    if session.permissionMode == mode { Label(mode.title, systemImage: "checkmark") } else { Text(mode.title) }
                }
            }
        } label: {
            QuietChip(title: session.permissionMode.title, systemImage: "lock.shield")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("Permission mode for the next turn")
    }

    private func toggle(_ title: String, systemImage: String, isOn: Bool, help: String, _ flip: @escaping (inout TurnSettings) -> Void) -> some View {
        Button { change(flip) } label: {
            QuietChip(title: title, systemImage: systemImage, isMenu: false, isOn: isOn)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func change(_ change: (inout TurnSettings) -> Void) {
        model.setTurnSettings(session.id, change)
    }
}

/// Puts the turn pickers in the session view composer's toolbar.
struct TurnSettingsAddOn: ComposerAddOn {
    func toolbar(_ context: ComposerContext) -> AnyView? {
        AnyView(TurnSettingsBar(session: context.session))
    }
}

/// The model and effort for the next turn as one quiet label in the composer, "Opus · High", with a
/// section per agent while it's a draft (the agent can still change) and an Effort section.
struct ModelEffortMenu: View {
    @Environment(AppModel.self) private var model
    let session: Session
    @State private var isHovered = false

    var body: some View {
        let current = model.modelChoices(for: session.provider).first { $0.id == session.model }
        Menu {
            ForEach(session.isDraft ? Provider.allCases : [session.provider], id: \.self) { provider in
                Section(session.isDraft ? provider.displayName : "Model") { models(for: provider) }
            }
            if let efforts = current?.efforts, !efforts.isEmpty {
                Section("Effort") {
                    check(current?.defaultEffort.map { "Default (\($0))" } ?? "Default", isOn: session.effort == nil) {
                        change { $0.effort = nil }
                    }
                    ForEach(efforts, id: \.self) { effort in
                        check(effort, isOn: session.effort == effort) { change { $0.effort = effort } }
                    }
                }
            }
        } label: {
            // Sort's small ghost button: 12 pt text, the chevron at the end with a tighter inset.
            HStack(spacing: 6) {
                Text(title(current)).font(.ui(12)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(isHovered ? Palette.text : Palette.textSecondary)
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .frame(height: 28)
            .background(isHovered ? Palette.text.opacity(0.1) : .clear, in: .rect(cornerRadius: ComposerMetrics.buttonRadius, style: .continuous))
            .contentShape(.rect)
            .onHover { isHovered = $0 }
            .animation(.hover, value: isHovered)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Model and effort for the next turn")
        .task(id: session.provider) { await model.loadModelChoices(for: session.provider) }
    }

    @ViewBuilder private func models(for provider: Provider) -> some View {
        let choices = model.modelChoices(for: provider)
        ForEach(choices) { choice in
            check(choice.title, isOn: provider == session.provider && choice.id == session.model) {
                if provider != session.provider { model.setDraftProvider(session.id, provider) }
                model.selectModel(choice, for: session.id)
            }
        }
        if choices.isEmpty {
            if session.isDraft {
                check("Default", isOn: provider == session.provider) { model.setDraftProvider(session.id, provider) }
            } else {
                Text("Loading models…")
            }
        }
    }

    /// "Opus · High", or just "Opus" on the model's default effort.
    private func title(_ current: ModelChoice?) -> String {
        let name = current?.title ?? (session.model.isEmpty ? "Default" : session.model)
        guard let effort = session.effort else { return name }
        return "\(name) · \(effort.prefix(1).uppercased() + effort.dropFirst())"
    }

    private func check(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if isOn { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    private func change(_ change: (inout TurnSettings) -> Void) {
        model.setTurnSettings(session.id, change)
    }
}
