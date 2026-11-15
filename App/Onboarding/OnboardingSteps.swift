import ConstellationCore
import ConstellationGit
import ConstellationProviders
import ImageIO
import SwiftUI

extension OnboardingStep {
    var title: String {
        switch self {
        case .welcome: "Constellation"
        case .agents: "Your agents"
        case .projects: "Pick your projects"
        case .background: "Pick a background"
        case .defaults: "How sessions start"
        case .keyboard: "Keys first"
        case .permissions: "Stay in the loop"
        case .done: "You're all set"
        }
    }

    var subtitle: String {
        switch self {
        case .welcome: "Every Claude Code and Codex session, a tile on your desktop. See what's working, what's done, and what needs you."
        case .agents: "Constellation runs Claude Code and Codex for you. You need at least one, signed in."
        case .projects: "Git repositories from your usual folders, newest first. Each gets its own piles on your desktop."
        case .background: "Your wallpaper, a view from NASA and Webb, a Hokusai print, an editor theme, or any image of yours. Your Mac's wallpaper stays as it is."
        case .defaults: "What a new session starts with. Each session can change it, and so can Settings."
        case .keyboard: "Try the keys on the desktop beside you. Skip any of them."
        case .permissions: "A notification when a session needs you, even with Constellation behind your other windows."
        case .done: "A few keys worth knowing, from your keymap."
        }
    }
}

/// The card for the current step.
struct StepCard: View {
    let onboarding: Onboarding

    var body: some View {
        switch onboarding.step {
        case .welcome: EmptyView()
        case .agents: AgentsCard(onboarding: onboarding)
        case .projects: ProjectsCard(onboarding: onboarding)
        case .background: BackgroundCard(onboarding: onboarding)
        case .defaults: DefaultsCard(onboarding: onboarding)
        case .keyboard: KeyboardCard(onboarding: onboarding)
        case .permissions: PermissionsCard(onboarding: onboarding)
        case .done: DoneCard(onboarding: onboarding)
        }
    }
}

// MARK: Background

/// Your wallpaper first, then the app's own pictures, three to a row. Picking one shows it on the
/// miniature at once.
private struct BackgroundCard: View {
    let onboarding: Onboarding
    @State private var thumbnails: [String: CGImage] = [:]

    var body: some View {
        let chosen = onboarding.settings.background
        VStack(alignment: .leading, spacing: 10) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 10) {
                        choice(index: 0, key: "", title: "Your wallpaper", isChosen: chosen == nil).id(0)
                        ForEach(Array(Background.all.enumerated()), id: \.element) { index, background in
                            choice(index: index + 1, key: background.id, title: background.title, isChosen: chosen == background.id).id(index + 1)
                        }
                    }
                    .padding(4)
                }
                .scrollIndicators(.never)
                .frame(height: 262)
                // Fade the last row out under the edge instead of cutting it mid-picture.
                .mask {
                    VStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom).frame(height: 24)
                    }
                }
                .onChange(of: onboarding.selection) { _, index in
                    withAnimation(.hover) { proxy.scrollTo(index, anchor: .center) }
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(caption(for: Background.named(chosen)))
                    .font(.ui(11))
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(2)
                Spacer(minLength: 4)
                Button("Choose your own…") {
                    if let path = Background.chooseYourOwn() { onboarding.settings.background = path }
                }
                .buttonStyle(ConstellationButtonStyle(weight: .quiet, height: 24))
            }
            .padding(.horizontal, 2)
        }
        .onboardingCard(padding: 12)
        .task { thumbnails = await Self.loadThumbnails() }
    }

    private func caption(for background: Background?) -> String {
        guard let background else { return "Change it any time in Settings." }
        return background.credit.isEmpty ? background.title : "Credit: \(background.credit)"
    }

    private func choice(index: Int, key: String, title: String, isChosen: Bool) -> some View {
        Button { onboarding.chooseBackground(at: index) } label: {
            VStack(alignment: .leading, spacing: 5) {
                Group {
                    if let image = thumbnails[key] {
                        Image(decorative: image, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                    } else {
                        Palette.surfaceSunken
                    }
                }
                .frame(height: 62)
                .frame(maxWidth: .infinity)
                .clipShape(.rect(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Palette.text.opacity(0.1))
                }
                .overlay(alignment: .bottomTrailing) {
                    if isChosen {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 15))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color(hex: 0x0B1A33), Palette.focus)
                            .padding(4)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                .keyboardSelected(onboarding.isSelected(index), cornerRadius: 8)
                Text(title)
                    .font(.ui(11, weight: isChosen ? .semibold : .regular))
                    .foregroundStyle(isChosen ? Palette.text : Palette.textSecondary)
                    .lineLimit(1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .animation(.hover, value: isChosen)
    }

    /// Small copies of every picture, keyed by its id and "" for your wallpaper, read off the main actor.
    private static func loadThumbnails() async -> [String: CGImage] {
        let sources = await MainActor.run {
            Background.all.compactMap { background in background.url.map { (background.id, $0) } }
                + [Wallpaper.url(for: NSScreen.screens.first).map { ("", $0) }].compactMap(\.self)
        }
        return await Task.detached(priority: .utility) {
            var thumbnails: [String: CGImage] = [:]
            for (key, url) in sources {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                          kCGImageSourceCreateThumbnailFromImageAlways: true,
                          kCGImageSourceCreateThumbnailWithTransform: true,
                          kCGImageSourceThumbnailMaxPixelSize: 360,
                      ] as CFDictionary) else { continue }
                thumbnails[key] = image
            }
            return thumbnails
        }.value
    }
}

// MARK: Agents

private struct AgentsCard: View {
    let onboarding: Onboarding

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 0) {
                ForEach(Array(Provider.allCases.enumerated()), id: \.element) { index, provider in
                    if index > 0 { Rectangle().fill(Palette.hairline).frame(width: 1).padding(.vertical, 8) }
                    ProviderCard(onboarding: onboarding, provider: provider, isSelected: onboarding.isSelected(index))
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .onboardingCard(padding: 8)
            if let fix = onboarding.fix {
                FixPanel(onboarding: onboarding, fix: fix)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if !onboarding.hasUsableProvider, onboarding.checking.isEmpty {
                Label("At least one agent is needed to continue.", systemImage: "info.circle")
                    .font(.ui(12.5))
                    .foregroundStyle(Palette.ask)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .animation(.onboarding, value: onboarding.fix)
        .animation(.hover, value: onboarding.hasUsableProvider)
    }
}

private struct ProviderCard: View {
    let onboarding: Onboarding
    let provider: Provider
    let isSelected: Bool

    private var status: ProviderStatus? { onboarding.statuses[provider] }
    private var isChecking: Bool { onboarding.checking.contains(provider) }

    var body: some View {
        VStack(spacing: 10) {
            ProviderMark(provider: provider)
            Text(provider.displayName).font(.ui(15, weight: .semibold)).foregroundStyle(Palette.text)
            badge
            Text(detail)
                .font(.ui(12))
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(height: 32, alignment: .top)
            Button(action: { onboarding.runFix(for: provider) }) {
                HStack(spacing: 5) {
                    if isChecking { ProgressView().controlSize(.mini).tint(Palette.ask) }
                    Text(actionTitle)
                }
            }
            .buttonStyle(PillButtonStyle(tint: status?.state == .ready ? Palette.textSecondary : Palette.ask))
            .disabled(isChecking)
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .background(isSelected ? Palette.rowHover : .clear, in: .rect(cornerRadius: 12, style: .continuous))
        .keyboardSelected(isSelected)
        .animation(.hover, value: status)
    }

    @ViewBuilder private var badge: some View {
        let (text, color) = OnboardingScene.statusLine(status, isChecking: isChecking)
        StatusBadge(text: text.prefix(1).uppercased() + text.dropFirst(), color: color, isFilled: status?.state == .ready)
    }

    private var detail: String {
        guard let status else { return "Looking on your PATH" }
        switch status.state {
        case .missing: return "Install it with one command, in a terminal here."
        case .signedOut: return "Installed\(status.version.map { " (\($0))" } ?? ""), not signed in yet."
        case .unknown: return "Version \(status.version ?? "unknown"). Couldn't check the sign-in."
        case .ready: return ["Version \(status.version ?? "?")", status.account].compactMap(\.self).joined(separator: "\n")
        }
    }

    private var actionTitle: String {
        if isChecking { return "Checking" }
        switch status?.state {
        case .missing?: return "Install"
        case .signedOut?, .unknown?: return "Sign in"
        default: return "Check again"
        }
    }
}

/// A provider's mark: an asterisk for Claude Code, brackets for Codex.
struct ProviderMark: View {
    let provider: Provider
    var size: CGFloat = 40

    /// Plain, in the provider's colour, rather than a glossy tile.
    var body: some View {
        Image(systemName: provider == .claudeCode ? "asterisk" : "chevron.left.forwardslash.chevron.right")
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(colors[0])
            .frame(width: size, height: size)
    }

    private var colors: [Color] {
        provider == .claudeCode ? [Color(hex: 0xEDA176), Color(hex: 0xC2603A)] : [Color(hex: 0x9AA4B4), Color(hex: 0x3E4756)]
    }
}

private struct FixPanel: View {
    let onboarding: Onboarding
    let fix: ProviderFix

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.icon)
                Text(fix.title).font(.ui(12.5, weight: .medium)).foregroundStyle(Palette.text)
                Spacer()
                Button("Check again") { onboarding.check(fix.provider) }
                    .buttonStyle(ConstellationButtonStyle(weight: .quiet, height: 22))
                Button { onboarding.fix = nil } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(ConstellationButtonStyle(weight: .quiet, height: 22))
                    .accessibilityLabel("Close terminal")
            }
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .frame(height: 32)
            Rectangle().fill(Palette.hairline).frame(height: 1)
            FixTerminal(fix: fix) { _ in onboarding.check(fix.provider) }
                .id(fix.id)
                .padding(8)
                .frame(height: 150)
        }
        .panelSurface(.card, cornerRadius: 12)
    }
}

// MARK: Projects

private struct ProjectsCard: View {
    let onboarding: Onboarding

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(onboarding.isScanning ? "Looking for repositories" : "\(onboarding.chosenProjects.count) chosen")
                    .font(.ui(12, weight: .semibold))
                    .foregroundStyle(Palette.textTertiary)
                    .contentTransition(.numericText())
                Spacer()
            }
            .padding(.horizontal, 4)
            if onboarding.projects.isEmpty {
                empty
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                            ForEach(Array(onboarding.projects.enumerated()), id: \.element.id) { index, choice in
                                ProjectCard(choice: choice, isSelected: onboarding.isSelected(index)) { onboarding.toggle(choice) }
                                    .id(index)
                            }
                        }
                        .padding(4)
                    }
                    .scrollIndicators(.never)
                    .frame(maxHeight: 268)
                    .fixedSize(horizontal: false, vertical: true)
                    // Fade the last row out under the edge instead of cutting it mid-line.
                    .mask {
                        VStack(spacing: 0) {
                            Color.black
                            LinearGradient(colors: [.black, .black.opacity(onboarding.projects.count > 6 ? 0 : 1)], startPoint: .top, endPoint: .bottom).frame(height: 28)
                        }
                    }
                    .onChange(of: onboarding.selection) { _, index in
                        withAnimation(.hover) { proxy.scrollTo(index) }
                    }
                }
            }
            VStack(spacing: 2) {
                ForEach(ProjectAction.allCases, id: \.self) { action in
                    ProjectActionRow(onboarding: onboarding, action: action)
                }
            }
            .padding(.horizontal, 4)
            Text("Or drop a folder anywhere on the screen.")
                .font(.ui(11.5))
                .foregroundStyle(Palette.textTertiary)
                .padding(.horizontal, 4)
        }
        .onboardingCard(padding: 12)
        .animation(.onboarding, value: onboarding.projects)
        .animation(.hover, value: onboarding.clone.isOpen)
    }

    @ViewBuilder private var empty: some View {
        Group {
            if onboarding.isScanning {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 60)
            } else {
                Text("No repositories found in your usual folders.")
                    .font(.ui(12))
                    .foregroundStyle(Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// Add a folder… or Clone from a URL…, quiet rows under the projects. Clone opens a URL field in
/// place, then shows its progress or what went wrong.
private struct ProjectActionRow: View {
    let onboarding: Onboarding
    let action: ProjectAction
    @FocusState private var isFieldFocused: Bool

    private var isSelected: Bool { onboarding.selectedProjectAction == action }
    private var showsField: Bool { action == .clone && onboarding.clone.isOpen }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsField { field } else { button }
            if action == .clone, case .entering(_, let message?) = onboarding.clone {
                Text(message)
                    .font(.ui(11))
                    .foregroundStyle(Palette.error)
                    .lineLimit(3)
                    .padding(.horizontal, 8)
            }
        }
    }

    private var button: some View {
        Button { onboarding.act(on: action) } label: {
            HStack(spacing: 8) {
                Image(systemName: action == .addFolder ? "folder" : "arrow.down.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textTertiary)
                    .frame(width: 16)
                Text(action == .addFolder ? "Add a folder…" : "Clone from a URL…")
                    .font(.ui(12.5))
                    .foregroundStyle(Palette.textSecondary)
                Spacer(minLength: 4)
                if action == .addFolder { KeyChip("⌘O").scaleEffect(0.85) }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(isSelected ? Palette.rowHover : .clear, in: .rect(cornerRadius: 7, style: .continuous))
            .keyboardSelected(isSelected, cornerRadius: 7)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var field: some View {
        HStack(spacing: 8) {
            if case .cloning = onboarding.clone {
                ProgressView().controlSize(.mini).frame(width: 16)
                Text("Cloning…").font(.ui(12.5)).foregroundStyle(Palette.textSecondary)
                Spacer(minLength: 4)
            } else {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textTertiary)
                    .frame(width: 16)
                TextField("https://github.com/owner/repo.git", text: Bindable(onboarding).cloneURL)
                    .textFieldStyle(.plain)
                    .font(.ui(12.5))
                    .focused($isFieldFocused)
                    .onSubmit(onboarding.startClone)
                Text("into ~/code").font(.ui(11)).foregroundStyle(Palette.textTertiary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Palette.surfaceSunken.opacity(0.55), in: .rect(cornerRadius: 7, style: .continuous))
        .keyboardSelected(isFieldFocused || isSelected, cornerRadius: 7)
        .onAppear { isFieldFocused = true }
    }
}

private struct ProjectCard: View {
    let choice: ProjectChoice
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(choice.name).font(.ui(12.5, weight: .medium)).foregroundStyle(Palette.text).lineLimit(1)
                    Spacer(minLength: 4)
                    check
                }
                Text(Self.abbreviated(choice.url.deletingLastPathComponent()))
                    .font(.ui(10.5))
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Text(when).font(.ui(11)).foregroundStyle(Palette.textTertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(choice.isChosen ? Palette.ask.opacity(0.1) : Palette.surfaceSunken.opacity(0.55), in: .rect(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(choice.isChosen ? Palette.ask.opacity(0.7) : Palette.text.opacity(0.08))
            }
            .keyboardSelected(isSelected, cornerRadius: 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(choice.isExisting)
        .animation(.hover, value: choice.isChosen)
    }

    private var check: some View {
        ZStack {
            Circle().strokeBorder(choice.isChosen ? Palette.ask : Palette.text.opacity(0.25), lineWidth: 1.5)
            if choice.isChosen {
                Circle().fill(Palette.ask)
                Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(Color(hex: 0x161513))
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: 16, height: 16)
    }

    private var when: String {
        if choice.isExisting { return "Already added" }
        guard let modified = choice.modified else { return "Added" }
        return LastUsed.label(modified, now: .now)
    }

    static func abbreviated(_ url: URL) -> String {
        url.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

// MARK: Defaults

private struct DefaultsCard: View {
    let onboarding: Onboarding

    private var settings: AppSettings { onboarding.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row(.provider, "Provider") {
                ForEach(Provider.allCases, id: \.self) { provider in
                    Pill(title: provider.displayName, isChosen: settings.defaultProvider == provider, isEnabled: onboarding.statuses[provider]?.isUsable ?? false) {
                        settings.defaultProvider = provider
                    }
                }
            }
            row(.model, "Model") {
                ForEach(ComposerDraft.models(for: settings.defaultProvider)) { model in
                    Pill(title: model.title, isChosen: settings.defaultModel == model.id) { settings.defaultModel = model.id }
                }
            }
            row(.effort, "Effort") {
                Pill(title: "Default", isChosen: settings.defaultEffort == nil) { settings.defaultEffort = nil }
                ForEach(AppSettings.efforts(for: settings.defaultProvider), id: \.self) { effort in
                    Pill(title: AppSettings.title(ofEffort: effort), isChosen: settings.defaultEffort == effort) { settings.defaultEffort = effort }
                }
            }
            row(.permissions, "Asks") {
                ForEach(PermissionMode.allCases, id: \.self) { mode in
                    Pill(title: mode.title, isChosen: settings.defaultPermissionMode == mode) { settings.defaultPermissionMode = mode }
                }
            } footer: {
                Text(LocalizedStringKey(Self.example(for: settings.defaultPermissionMode)))
                    .font(.ui(11.5))
                    .foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                    .animation(.hover, value: settings.defaultPermissionMode)
            }
            row(.worktree, "Worktree") {
                Pill(title: "New worktree", isChosen: settings.defaultNewWorktree) { settings.defaultNewWorktree = true }
                Pill(title: "In the project folder", isChosen: !settings.defaultNewWorktree) { settings.defaultNewWorktree = false }
            } footer: {
                HStack(spacing: 6) {
                    Text(ProjectCard.abbreviated(settings.effectiveWorktreeRoot))
                        .font(.ui(11))
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Change…", action: chooseWorktreeRoot)
                        .buttonStyle(ConstellationButtonStyle(weight: .quiet, height: 20))
                }
                .opacity(settings.defaultNewWorktree ? 1 : 0.4)
            }
        }
        .onboardingCard(padding: 10)
    }

    private func row<Choices: View>(_ row: Onboarding.DefaultsRow, _ label: String, @ViewBuilder choices: () -> Choices) -> some View {
        self.row(row, label, choices: choices) { EmptyView() }
    }

    private func row<Choices: View, Footer: View>(
        _ row: Onboarding.DefaultsRow, _ label: String, @ViewBuilder choices: () -> Choices, @ViewBuilder footer: () -> Footer
    ) -> some View {
        let index = Onboarding.DefaultsRow.allCases.firstIndex(of: row) ?? 0
        let isSelected = onboarding.isSelected(index)
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.ui(12.5, weight: .medium))
                .foregroundStyle(isSelected ? Palette.text : Palette.textTertiary)
                .frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) { choices() }
                footer()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isSelected ? Palette.rowHover : .clear, in: .rect(cornerRadius: 10, style: .continuous))
        .animation(.hover, value: isSelected)
    }

    static func example(for mode: PermissionMode) -> String {
        switch mode {
        case .askForEverything: "Asks before every file edit and every command, even `ls`."
        case .askForRisky: "Edits files freely. Asks before commands like `npm install` or `git push`."
        case .fullAuto: "Never asks. Best with a worktree, so main stays untouched."
        }
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
}

/// A rounded choice in a row of them.
struct Pill: View {
    let title: String
    let isChosen: Bool
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.ui(12.5, weight: isChosen ? .semibold : .medium))
                .foregroundStyle(isChosen ? Color(hex: 0x161513) : Palette.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(isChosen ? Palette.text : Palette.surfaceRaised.opacity(0.8), in: .capsule)
                .overlay { if !isChosen { Capsule().strokeBorder(Palette.text.opacity(0.1)) } }
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .animation(.hover, value: isChosen)
    }
}

// MARK: Keyboard

private struct KeyboardCard: View {
    let onboarding: Onboarding

    var body: some View {
        VStack(spacing: 2) {
            lesson(.move, "Move between piles", caps: ["←", "→"])
            lesson(.cycle, "Turn through a pile", caps: ["⇥"])
            lesson(.attention, "Jump to what needs you", caps: ["⌥", "⇥"])
            lesson(.digits, "Hold ⌘ for numbers, then ⌘1 to ⌘3", caps: ["⌘"])
            lesson(.summon, "Summon Constellation from any app", caps: ["⌥", "space"])
        }
        .onboardingCard(padding: 14)
    }

    private func lesson(_ lesson: KeyLesson, _ text: String, caps: [String]) -> some View {
        let isDone = onboarding.lessonsDone.contains(lesson)
        return HStack(spacing: 10) {
            ZStack {
                Circle().strokeBorder(isDone ? Palette.done : Palette.text.opacity(0.2), lineWidth: 1.5)
                if isDone {
                    Circle().fill(Palette.done)
                    Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(Color(hex: 0x161513))
                }
            }
            .frame(width: 16, height: 16)
            Text(text)
                .font(.ui(13))
                .foregroundStyle(isDone ? Palette.textSecondary : Palette.text)
            Spacer()
            HStack(spacing: 3) { ForEach(caps, id: \.self) { KeyChip($0) } }
                .opacity(isDone ? 0.5 : 1)
        }
        .padding(.horizontal, 6)
        .frame(height: 32)
        .background(isDone ? Palette.done.opacity(0.08) : .clear, in: .rect(cornerRadius: 8))
        .animation(.onboarding, value: isDone)
    }
}

// MARK: Permissions

private struct PermissionsCard: View {
    let onboarding: Onboarding

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 0) {
                notifications
                if onboarding.permissionCards.contains(.fullDiskAccess) {
                    Rectangle().fill(Palette.hairline).frame(width: 1).padding(.vertical, 8)
                    fullDiskAccess
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .onboardingCard(padding: 8)
            privacyLine
        }
        .animation(.onboarding, value: onboarding.permissionCards)
    }

    private var notifications: some View {
        let status = onboarding.notificationStatus
        let (badge, color, isFilled): (String, Color, Bool) = switch status {
        case .authorized?, .provisional?: ("Allowed", Palette.done, true)
        case .denied?: ("Turned off", Palette.error, false)
        default: ("Recommended", Palette.ask, false)
        }
        return PermissionTile(
            symbol: "bell.badge.fill", tint: [Color(hex: 0xF2C072), Color(hex: 0xC4663F)],
            title: "Notifications", badge: badge, badgeColor: color, badgeFilled: isFilled,
            text: "A banner when a session needs you or fails. Allow once and Deny right from it.",
            action: status == .notDetermined || status == nil ? "Allow…" : status == .denied ? "Open Settings" : nil,
            isSelected: onboarding.isSelected(0)
        ) { onboarding.act(on: .notifications) }
    }

    private var fullDiskAccess: some View {
        let folders = onboarding.blockedFolders ?? []
        return PermissionTile(
            symbol: "externaldrive.fill.badge.checkmark", tint: [Color(hex: 0xA9C6EA), Color(hex: 0x4F72A3)],
            title: "Full Disk Access", badge: "Needed", badgeColor: Palette.ask, badgeFilled: false,
            text: "Tools can't read \(folders.first?.lastPathComponent ?? "your project") yet. This lets them into Documents and Desktop.",
            action: "Open Settings",
            isSelected: onboarding.isSelected(1)
        ) { onboarding.act(on: .fullDiskAccess) }
    }

    /// Only said when a chosen project sits somewhere macOS guards.
    @ViewBuilder private var privacyLine: some View {
        if onboarding.chosenProjects.contains(where: { PrivacyCheck.isProtected($0.url) }) {
            privacyStatus
        }
    }

    private var privacyStatus: some View {
        HStack(spacing: 8) {
            switch onboarding.blockedFolders {
            case nil:
                ProgressView().controlSize(.mini)
                Text("Checking your projects can be read…")
            case let blocked? where blocked.isEmpty:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.done)
                Text("Your projects are readable, so Full Disk Access isn't needed.")
            case let blocked?:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.ask)
                Text("Blocked: \(blocked.map(\.lastPathComponent).joined(separator: ", ")). Turn on Constellation, then come back.")
            }
        }
        .font(.ui(12))
        .foregroundStyle(Palette.textSecondary)
        .padding(.horizontal, 4)
    }
}

private struct PermissionTile: View {
    let symbol: String
    let tint: [Color]
    let title: String
    let badge: String
    let badgeColor: Color
    let badgeFilled: Bool
    let text: String
    let action: String?
    let isSelected: Bool
    let perform: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(tint[0])
                .frame(height: 32)
            Text(title).font(.ui(15, weight: .semibold)).foregroundStyle(Palette.text)
            StatusBadge(text: badge, color: badgeColor, isFilled: badgeFilled)
            Text(text)
                .font(.ui(12))
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                Button(action, action: perform).buttonStyle(PillButtonStyle())
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .background(isSelected ? Palette.rowHover : .clear, in: .rect(cornerRadius: 12, style: .continuous))
        .keyboardSelected(isSelected)
    }
}

// MARK: Done

private struct DoneCard: View {
    let onboarding: Onboarding

    var body: some View {
        VStack(spacing: 0) {
            key("Command palette", .palette)
            Rectangle().fill(Palette.hairline).frame(height: 1)
            key("New session", .sessionNew)
            Rectangle().fill(Palette.hairline).frame(height: 1)
            key("Work through what needs you", .triage)
            Rectangle().fill(Palette.hairline).frame(height: 1)
            key("Show the sidebar", .sidebarToggle)
        }
        .onboardingCard(padding: 6)
    }

    private func key(_ title: String, _ id: ActionID) -> some View {
        HStack {
            Text(title).font(.ui(14)).foregroundStyle(Palette.text)
            Spacer()
            BindingChips(binding: onboarding.model.binding(for: id))
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
    }
}
