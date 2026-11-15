import ConstellationCore
import SwiftUI

/// "Start a session": the card an empty desktop shows. One row per project, most recently used
/// first, then "New project…" and "Open folder…". The search field at the top has the keys from the
/// start: typing filters, ↑↓ move the selected row while the cursor stays in the field, ↵ or
/// ⌥+digit open, and esc clears the search, then puts the card away.
/// The ⌥ keys show on the rows only while ⌥ is held; the summon key sits at the end of the field.
struct EmptyStateLauncher: View {
    @Environment(AppModel.self) private var model
    /// The widest project name, so every row's path starts in the same column.
    @State private var nameWidth: CGFloat = 96
    @FocusState private var isSearching: Bool

    static let width: CGFloat = 520

    var body: some View {
        let rows = model.launcherProjects
        let isCovered = model.launcherIsCovered || model.sheet != nil
        GeometryReader { proxy in
            // A click outside the card puts it away, as esc does, when there's a desktop to go back to.
            Color.clear
                .contentShape(.rect)
                .onTapGesture { model.dismissLauncher() }
                .allowsHitTesting(!isCovered && model.canDismissLauncher)
            VStack(spacing: 0) {
                header
                Rectangle().fill(Palette.hairline).frame(height: 1)
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, project in
                        ProjectRow(project: project, index: index, isSelected: index == model.launcher.selection, nameWidth: nameWidth)
                    }
                    if rows.isEmpty {
                        Text("No project matches \u{201C}\(model.launcher.query)\u{201D}")
                            .font(.ui(13))
                            .foregroundStyle(Palette.textTertiary)
                            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                            .padding(.leading, 10)
                    }
                    Rectangle().fill(Palette.hairline).frame(height: 1).padding(.horizontal, 10).padding(.vertical, 5)
                    ForEach(LauncherActionRow.allCases, id: \.self) { row in
                        ActionRow(row: row, index: rows.count + row.rawValue, isSelected: rows.count + row.rawValue == model.launcher.selection)
                    }
                }
                .padding(6)
                .background {
                    // Measures the names off screen; the rows lay theirs out at the widest.
                    VStack(alignment: .leading) {
                        ForEach(rows) { Text($0.name).font(.ui(13)).fixedSize() }
                    }
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { nameWidth = min(160, max(96, $0)) }
                }
            }
            .frame(width: Self.width)
            .panelSurface()
            .opacity(isCovered ? 0 : 1)
            .scaleEffect(isCovered ? 0.98 : 1)
            .animation(isCovered ? .fadeOut : .fadeIn, value: isCovered)
            .allowsHitTesting(!isCovered)
            .frame(width: proxy.size.width)
            .padding(.top, max(40, proxy.size.height * 0.26))
        }
        .transition(.opacity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Start a session")
        .onAppear { isSearching = true }
        // Back to the field when a draft's panel goes, or ⌘N brings the card up again.
        .onChange(of: isCovered) { _, covered in if !covered { isSearching = true } }
        .onChange(of: model.launcher.presence) { _, presence in if presence == .summoned { isSearching = true } }
    }

    private var header: some View {
        @Bindable var launcher = model.launcher
        return HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.textTertiary)
            TextField("Start a session in…", text: $launcher.query)
                .textFieldStyle(.plain)
                .font(.ui(15))
                .foregroundStyle(Palette.text)
                .focused($isSearching)
                // The rows answer while the cursor stays here, as a list's active row would.
                .onKeyPress(.upArrow) { move(by: -1) }
                .onKeyPress(.downArrow) { move(by: 1) }
                .onKeyPress(.escape) {
                    if !launcher.query.isEmpty {
                        launcher.query = ""
                    } else if model.canDismissLauncher {
                        model.dismissLauncher()
                    }
                    return .handled
                }
                .onSubmit { model.openSelectedLauncherRow() }
                .accessibilityLabel("Find a project")
                .accessibilityHint("Up and down choose a project; Return starts a session in it")
            if !launcher.query.isEmpty {
                Button { launcher.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12))
                }
                .buttonStyle(IconButtonStyle(width: 22, height: 22))
                .help("Clear (esc)")
                .accessibilityLabel("Clear search")
            } else {
                Button { model.perform(.palette) } label: {
                    HStack(spacing: 4) {
                        ForEach(Array(summonKeys.keys.enumerated()), id: \.offset) { _, key in KeyChip(key) }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(summonKeys.label == "commands" ? "Commands" : "Start a session from any app")
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .frame(height: 46)
    }

    /// Moves the selected row and says which it is, as focus stays in the field.
    private func move(by delta: Int) -> KeyPress.Result {
        model.moveLauncherSelection(by: delta)
        let rows = model.launcherProjects
        let index = model.launcher.selection
        let name = rows.indices.contains(index) ? rows[index].name : LauncherActionRow(rawValue: index - rows.count).map { $0 == .newProject ? "New project" : "Open folder" }
        if let name { AccessibilityNotification.Announcement(name).post() }
        return .handled
    }

    /// The global summon hotkey once the keymap has one, otherwise the palette's own key.
    private var summonKeys: (keys: [String], label: String) {
        if let summon = model.keyboard.keymap.entries(for: ActionID.appSummon.rawValue, argument: nil, global: true).first {
            return (KeyChips.caps(for: summon.rule.strokes), "from any app")
        }
        return (model.binding(for: .palette).map { KeyChips.caps(for: $0.strokes) } ?? ["⌘", "K"], "commands")
    }
}

private struct ProjectRow: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let index: Int
    let isSelected: Bool
    let nameWidth: CGFloat
    @State private var isHovered = false

    var body: some View {
        Button { model.openFromLauncher(project.id) } label: {
            HStack(spacing: 12) {
                ProjectMark(project: project)
                Text(project.name).font(.ui(13)).foregroundStyle(Palette.text).lineLimit(1).frame(width: nameWidth, alignment: .leading)
                Text(DisplayPath.abbreviated(project.rootPath))
                    .font(.ui(12))
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let lastUsed = model.lastUsed(project.id) {
                    Text(LastUsed.label(lastUsed, now: .now)).font(.ui(12)).foregroundStyle(Palette.textTertiary).lineLimit(1)
                        // One column wide, so the paths end together.
                        .frame(minWidth: 60, alignment: .trailing)
                }
                if index < 9, model.keyboard.showsOptionHints {
                    HStack(spacing: 2) { KeyChip("⌥"); KeyChip("\(index + 1)") }
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .frame(height: 34)
            .background(isSelected ? Palette.rowSelected : isHovered ? Palette.rowHover : .clear, in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .onContinuousHover { phase in
            if case .active = phase, PointerHover.moved() { model.launcher.selection = index }
        }
        .animation(.constellation, value: isHovered)
        .accessibilityLabel("\(project.name), \(DisplayPath.abbreviated(project.rootPath))")
        .accessibilityHint("Starts a new session in this project")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// "New project…" or "Open folder…", under the projects. Selected and hovered as project rows are.
private struct ActionRow: View {
    @Environment(AppModel.self) private var model
    let row: LauncherActionRow
    let index: Int
    let isSelected: Bool
    @State private var isHovered = false

    var body: some View {
        Button { model.runLauncherRow(row) } label: {
            HStack(spacing: 12) {
                Image(systemName: row == .newProject ? "plus" : "folder")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.textTertiary)
                    .frame(width: 13)
                Text(row == .newProject ? "New project…" : "Open folder…")
                    .font(.ui(13))
                    .foregroundStyle(isSelected ? Palette.text : Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if model.keyboard.showsOptionHints {
                    HStack(spacing: 2) { KeyChip("⌥"); KeyChip(row == .newProject ? "N" : "O", font: .ui(12, weight: .medium)) }
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .frame(height: 34)
            .background(isSelected ? Palette.rowSelected : isHovered ? Palette.rowHover : .clear, in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .onContinuousHover { phase in
            if case .active = phase, PointerHover.moved() { model.launcher.selection = index }
        }
        .animation(.constellation, value: isHovered)
        .accessibilityHint(row == .newProject ? "Makes a new git repository to start sessions in" : "Adds a git repository as a project")
    }
}

/// "2h ago", "yesterday", "3d ago", as the launcher shows when a project was last used.
enum LastUsed {
    static func label(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "just now"
        case ..<3_600: return "\(seconds / 60)m ago"
        case ..<86_400: return "\(seconds / 3_600)h ago"
        case ..<172_800: return "yesterday"
        default: return "\(seconds / 86_400)d ago"
        }
    }
}
