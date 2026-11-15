import AppKit
import ConstellationCore
import SwiftUI

/// ⌘,. New-session defaults, worktrees, clean-up, editor, notifications, the desktop, keys and usage.
struct SettingsView: View {
    let model: AppModel
    @State private var section: SettingsSection = .general

    var body: some View {
        HStack(spacing: 0) {
            rail
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Palette.surface)
        }
        .frame(width: 760, height: 560)
        .background(Palette.popover)
        // Cream rather than system blue or amber: quiet on pickers, clear on switches.
        .tint(Palette.text)
        .environment(\.font, .ui(13))
    }

    /// The sections down the left, in the desktop sidebar's style, under the window's traffic lights.
    private var rail: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Settings")
                .font(.ui(13, weight: .semibold))
                .foregroundStyle(Palette.text)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            ForEach(SettingsSection.allCases) { item in
                Button { section = item } label: {
                    Image(systemName: item.symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.icon).frame(width: 16)
                    Text(item.title).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(SidebarRowStyle(isSelected: section == item))
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 44)
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
        .frame(width: 190)
    }

    @ViewBuilder private var content: some View {
        switch section {
        case .general: GeneralSettings(settings: model.settings, runOnboarding: runOnboarding)
        case .notifications: NotificationSettings(settings: model.settings)
        case .desktop: DesktopSettings(settings: model.settings)
        case .keyboard: KeyboardSettings(model: model)
        case .usage: UsageSettings(model: model)
        }
    }

    private func runOnboarding() {
        SettingsWindow.shared.close()
        model.beginOnboarding()
    }
}

private struct GeneralSettings: View {
    @Bindable var settings: AppSettings
    let runOnboarding: () -> Void

    var body: some View {
        Form {
            Section("New sessions") {
                Picker("Provider", selection: $settings.defaultProvider) {
                    ForEach(Provider.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("Model", selection: $settings.defaultModel) {
                    ForEach(ComposerDraft.models(for: settings.defaultProvider)) { Text($0.title).tag($0.id) }
                }
                Picker("Effort", selection: $settings.defaultEffort) {
                    Text("Default").tag(String?.none)
                    ForEach(AppSettings.efforts(for: settings.defaultProvider), id: \.self) { Text(AppSettings.title(ofEffort: $0)).tag(Optional($0)) }
                }
                Picker("Permissions", selection: $settings.defaultPermissionMode) {
                    ForEach(PermissionMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("New worktree for each session", isOn: $settings.defaultNewWorktree)
            }
            Section {
                LabeledContent("Worktree folder") {
                    HStack(spacing: 8) {
                        Text(Self.abbreviated(settings.effectiveWorktreeRoot))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…", action: chooseWorktreeRoot)
                        if settings.worktreeRoot != nil {
                            Button("Default") { settings.worktreeRoot = nil }
                        }
                    }
                }
                LabeledContent("New projects folder") {
                    HStack(spacing: 8) {
                        Text(settings.newProjectsFolder.map(Self.abbreviated) ?? "Next to your latest project")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…", action: chooseNewProjectsFolder)
                        if settings.newProjectsFolder != nil {
                            Button("Default") { settings.newProjectsFolder = nil }
                        }
                    }
                }
            } footer: {
                Text("New worktrees go in a folder per project here. Existing ones stay where they are. New project makes its folder in the new projects folder.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Clean-up") {
                Picker("Suggest clean-up after", selection: $settings.cleanupThreshold) {
                    ForEach(CleanupThreshold.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            Section("Editor") {
                Picker("Open worktrees in", selection: editor) {
                    ForEach(Editor.installed) { editor in
                        Text(editor.title).tag(editor)
                    }
                }
            }
            Section {
                LabeledContent("Agents, projects and keys") {
                    Button("Run Onboarding…", action: runOnboarding)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var editor: Binding<Editor> {
        Binding { settings.preferredEditor } set: { settings.editor = $0 }
    }

    private func chooseWorktreeRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.directoryURL = settings.effectiveWorktreeRoot
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.worktreeRoot = url
    }

    private func chooseNewProjectsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.directoryURL = settings.newProjectsFolder ?? URL.homeDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.newProjectsFolder = url
    }

    static func abbreviated(_ url: URL) -> String {
        url.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

private struct NotificationSettings: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle("When a session needs you", isOn: $settings.notifiesWhenBlocked)
                Toggle("When a session fails", isOn: $settings.notifiesWhenFailed)
            } footer: {
                Text("The Dock badge always counts sessions that need you.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Nudge cards that need you", isOn: $settings.wigglesForAttention)
                Toggle("Cards drift gently", isOn: $settings.cardsDrift)
            } header: {
                Text("On the desktop")
            } footer: {
                Text("Both stop while Reduce Motion is on.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct DesktopSettings: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker("Arrangement", selection: $settings.desktopArrangement) {
                    ForEach(PileArrangement.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(settings.desktopArrangement.summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("Background", selection: $settings.background) {
                    Text("Your wallpaper").tag(String?.none)
                    ForEach(Background.all) { Text($0.title).tag(Optional($0.id)) }
                    if let yours = Background.named(settings.background), yours.isYours {
                        Text(yours.title).tag(Optional(yours.id))
                    }
                }
                LabeledContent("Your own image") {
                    Button("Choose…") { if let path = Background.chooseYourOwn() { settings.background = path } }
                }
            } footer: {
                Text(Background.named(settings.background).flatMap { $0.credit.isEmpty ? nil : "Credit: \($0.credit)" } ?? "Behind your piles only; your Mac's wallpaper stays as it is.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension PileArrangement {
    var title: String {
        switch self {
        case .expose: "Exposé"
        case .grid: "Grid"
        }
    }

    var summary: String {
        switch self {
        case .expose: "Piles fill the screen in rows, as large as fits, in an order you set by dropping one on another. New ones join their project's piles."
        case .grid: "Piles sit in rows of equal slots. Dropping one on another swaps them. New ones take the free slot nearest their project."
        }
    }
}

/// Totals per day for the last 30 days, from the store.
private struct UsageSettings: View {
    let model: AppModel
    @State private var days: [DayRow] = []

    struct DayRow: Identifiable, Hashable {
        var id: String { day }
        var day: String
        var claudeCode = UsageTotals()
        var codex = UsageTotals()

        var total: UsageTotals {
            var total = claudeCode
            total.add(codex)
            return total
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Last 30 days").font(.headline)
                Spacer()
                Text(summary(of: days.reduce(into: UsageTotals()) { $0.add($1.total) }))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Table(days) {
                TableColumn("Day") { row in Text(Self.title(of: row.day)) }
                TableColumn("Claude Code") { row in Text(tokens(row.claudeCode)).monospacedDigit() }
                TableColumn("Codex") { row in Text(tokens(row.codex)).monospacedDigit() }
                TableColumn("Cost") { row in Text(row.total.costUSD.map(UsageFormat.cost) ?? "-").monospacedDigit() }
            }
            .frame(height: 300)
            .overlay {
                if days.isEmpty {
                    Text("No usage yet. Tokens and cost show here once a session runs.")
                        .foregroundStyle(.secondary)
                }
            }
            Text("Claude Code reports cost; Codex reports tokens only. Totals stay after clean-up.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .task(id: model.usage) { await load() }
    }

    private func load() async {
        let store = model.services.store
        let since = DailyUsage.dayKey(for: Calendar.current.date(byAdding: .day, value: -29, to: .now) ?? .now)
        let daily = await Task.detached { (try? store.dailyUsage(since: since)) ?? [] }.value
        var rows: [String: DayRow] = [:]
        for entry in daily {
            switch entry.provider {
            case .claudeCode: rows[entry.day, default: DayRow(day: entry.day)].claudeCode = entry.totals
            case .codex: rows[entry.day, default: DayRow(day: entry.day)].codex = entry.totals
            }
        }
        days = rows.values.sorted { $0.day > $1.day }
    }

    private func tokens(_ totals: UsageTotals) -> String {
        totals.totalTokens == 0 ? "-" : UsageFormat.tokens(totals.totalTokens)
    }

    private func summary(of totals: UsageTotals) -> String {
        let tokens = "\(UsageFormat.tokens(totals.totalTokens)) tokens"
        return totals.costUSD.map { "\(tokens) · \(UsageFormat.cost($0))" } ?? tokens
    }

    private static func title(of day: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: day) else { return day }
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, notifications, desktop, keyboard, usage

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .notifications: "Notifications"
        case .desktop: "Desktop"
        case .keyboard: "Keyboard"
        case .usage: "Usage"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .notifications: "bell"
        case .desktop: "square.stack"
        case .keyboard: "keyboard"
        case .usage: "chart.bar"
        }
    }
}
