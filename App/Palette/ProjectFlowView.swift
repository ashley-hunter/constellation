import ConstellationCore
import ConstellationGit
import SwiftUI

/// The palette's Add project flow. The menu offers New project and Local folder. Local folder's
/// field is a path, listing the subfolders of its folder part that start with what follows the
/// last /; New project's field is a name, or a path below the new projects folder when it has a /.
/// Tab completes as a shell does, ↵ goes into the selected folder, ⌘↵ adds or creates, and ⌫ on
/// an empty field steps back.
struct ProjectFlowView: View {
    @Environment(AppModel.self) private var model
    let flow: ProjectFlow
    /// Moves to another step, or back to the palette's own list with nil.
    let go: (ProjectFlow?) -> Void
    @State private var text: String
    @State private var selection: Int?
    /// The last folder listed and its subfolders, so typing within one folder lists it once.
    @State private var listing: (folder: URL, subfolders: [BrowsedFolder])?
    @State private var error: String?
    @State private var isWorking = false
    @State private var enclosingRepository: URL?
    @FocusState private var isFocused: Bool
    @State private var backMonitor: Any?

    init(flow: ProjectFlow, text: String, go: @escaping (ProjectFlow?) -> Void) {
        self.flow = flow
        self.go = go
        _text = State(initialValue: text)
        _selection = State(initialValue: flow == .newProject ? nil : 0)
    }

    var body: some View {
        let rows = folderRows
        VStack(alignment: .leading, spacing: 0) {
            field
            if flow == .menu {
                list(count: menuRows.count) { index in menuRow(menuRows[index], isSelected: index == selection) }
            } else {
                if flow == .newProject { summary }
                if let message = error ?? warning {
                    Text(message)
                        .font(.ui(12))
                        .foregroundStyle(error != nil ? Palette.error : Palette.ask)
                        .lineLimit(2)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
                if isBrowsing {
                    if rows.isEmpty, flow == .openFolder {
                        Text(split.leaf.isEmpty ? "No folders here" : "No folder starts with \u{201C}\(split.leaf)\u{201D}")
                            .font(.ui(13))
                            .foregroundStyle(Palette.textTertiary)
                            .padding(16)
                    } else {
                        list(count: rows.count) { index in folderRow(rows[index], isSelected: index == selection) }
                    }
                }
            }
            footer
        }
        .task {
            // Again a moment later: a composer that just closed can leave focus nowhere.
            isFocused = true
            try? await Task.sleep(for: .milliseconds(100))
            isFocused = true
        }
        // ⌫ on an empty field steps back. The text field keeps delete to itself, so this watches
        // for it while the flow shows.
        .onAppear {
            backMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 51, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return event }
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard isFocused, text.isEmpty else { return false }
                    go(flow == .menu ? nil : .menu)
                    return true
                }
                return handled ? nil : event
            }
        }
        .onDisappear {
            if let backMonitor { NSEvent.removeMonitor(backMonitor) }
        }
        .onChange(of: directory, initial: true) { _, directory in
            listing = (directory, FolderListing.subfolders(of: directory))
        }
        .onChange(of: text) {
            PointerHover.settle()
            selection = flow == .newProject ? nil : 0
            error = nil
        }
        .task(id: flow == .newProject ? directory : nil) {
            enclosingRepository = nil
            guard flow == .newProject else { return }
            enclosingRepository = await model.enclosingRepository(of: directory)
        }
    }

    // MARK: The typed path

    /// Local folder resolves paths from home; New project from the new projects folder.
    private var base: URL { flow == .newProject ? model.newProjectsRoot : URL.homeDirectory }

    private var split: (directory: String, leaf: String) { PathCompletion.split(text) }

    /// The folder whose subfolders are listed, and the one a new project goes in.
    private var directory: URL { PathCompletion.resolve(split.directory, base: base) }

    /// New project lists folders only once you type a /.
    private var isBrowsing: Bool { flow == .openFolder || (flow == .newProject && text.contains("/")) }

    private var folderRows: [BrowsedFolder] {
        guard isBrowsing else { return [] }
        // Typing fast can get ahead of the listing, so a stale one is never used.
        let directory = directory
        let folders = listing.flatMap { $0.folder == directory ? $0.subfolders : nil } ?? FolderListing.subfolders(of: directory)
        let names = Set(PathCompletion.matches(folders.map(\.name), leaf: split.leaf))
        return folders.filter { names.contains($0.name) }
    }

    private var warning: String? {
        enclosingRepository.map { "Inside the \($0.lastPathComponent) repository, so this makes a repository within it." }
    }

    // MARK: Field

    private var field: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Text(title).font(.ui(12, weight: .medium)).foregroundStyle(Palette.textSecondary)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.textTertiary)
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(.white.opacity(0.06), in: .rect(cornerRadius: 6))
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(flow == .openFolder ? .ui(14) : .ui(15))
                .focused($isFocused)
                .onSubmit { submit(folderRows) }
                .onKeyPress(.downArrow) { move(1, count: rowCount(folderRows)) }
                .onKeyPress(.upArrow) { move(-1, count: rowCount(folderRows)) }
                .onKeyPress(.tab) { complete(folderRows) }
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    primary()
                    return .handled
                }
            if flow != .menu {
                Button(action: primary) {
                    HStack(spacing: 8) {
                        Text(flow == .newProject ? "Create" : "Add")
                        HStack(spacing: 2) { KeyChip("⌘"); KeyChip("↵") }
                    }
                }
                .buttonStyle(.secondary)
                .disabled(isWorking)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }

    private var title: String {
        switch flow {
        case .menu: "Add project"
        case .newProject: "New project"
        case .openFolder: "Local folder"
        }
    }

    private var placeholder: String {
        switch flow {
        case .menu: "Add a project"
        case .newProject: "Project name"
        case .openFolder: "Path to a git repository"
        }
    }

    // MARK: Rows

    private struct MenuRow {
        let flow: ProjectFlow
        let title: String
        let detail: String
        let systemImage: String
    }

    private var menuRows: [MenuRow] {
        let rows = [
            MenuRow(flow: .newProject, title: "New project", detail: "A new folder with git in it", systemImage: "plus"),
            MenuRow(flow: .openFolder, title: "Local folder", detail: "A git repository on this Mac", systemImage: "folder"),
        ]
        return FuzzyMatch.rank(text.trimmingCharacters(in: .whitespaces), rows, limit: rows.count) { $0.title }
    }

    private func rowCount(_ rows: [BrowsedFolder]) -> Int {
        flow == .menu ? menuRows.count : rows.count
    }

    private func list<Row: View>(count: Int, @ViewBuilder row: @escaping (Int) -> Row) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(0..<count, id: \.self) { index in
                        row(index)
                            .id(index)
                            .onContinuousHover { phase in
                                if case .active = phase, PointerHover.moved() { selection = index }
                            }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: selection) { _, index in
                if let index { proxy.scrollTo(index) }
            }
        }
    }

    private func menuRow(_ row: MenuRow, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: row.systemImage).font(.system(size: 12)).foregroundStyle(Palette.icon).frame(width: 16)
            Text(row.title).font(.ui(13)).foregroundStyle(Palette.text)
            Spacer(minLength: 8)
            Text(row.detail).font(.ui(12)).foregroundStyle(Palette.textTertiary).lineLimit(1)
        }
        .paletteRow(isSelected: isSelected)
        .onTapGesture { go(row.flow) }
    }

    private func folderRow(_ folder: BrowsedFolder, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(Palette.icon).frame(width: 16)
            Text(folder.name).font(.ui(13)).foregroundStyle(Palette.text).lineLimit(1).truncationMode(.middle)
            if folder.isRepository {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Palette.textTertiary)
                    .help("Git repository")
                    .accessibilityLabel("git repository")
            }
            Spacer(minLength: 8)
            if isSelected { KeyChip("↵") }
        }
        .paletteRow(isSelected: isSelected)
        .onTapGesture { enter(folder.name) }
    }

    /// New project's summary: where it goes until named, then exactly what it makes.
    private var summary: some View {
        let leaf = split.leaf.trimmingCharacters(in: .whitespaces)
        return HStack(spacing: 8) {
            Image(systemName: "folder.badge.plus").font(.system(size: 12)).foregroundStyle(Palette.icon).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(leaf.isEmpty ? "New project" : leaf).font(.ui(13)).foregroundStyle(Palette.text).lineLimit(1)
                HStack(spacing: 4) {
                    Text(leaf.isEmpty ? "Goes in" : "Creates").font(.ui(12))
                    Text(DisplayPath.abbreviated(leaf.isEmpty ? directory : directory.appending(path: leaf)))
                        .font(.ui(12))
                        .truncationMode(.head)
                }
                .foregroundStyle(Palette.textTertiary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// The one key worth knowing at this step; the rest are the usual ones.
    private var footer: some View {
        HStack(spacing: 12) {
            switch flow {
            case .menu: KeyHint(key: "↵", label: "choose")
            case .newProject: KeyHint(key: "/", label: "choose where")
            case .openFolder: KeyHint(key: "tab", label: "complete")
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
        .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }

    // MARK: Keys

    private func move(_ offset: Int, count: Int) -> KeyPress.Result {
        guard count > 0 else { return .ignored }
        PointerHover.settle()
        guard let current = selection else {
            selection = offset > 0 ? 0 : nil
            return .handled
        }
        let next = current + offset
        // New project can step back off the list, so ↵ creates again.
        selection = next < 0 ? (flow == .newProject ? nil : 0) : min(next, count - 1)
        return .handled
    }

    /// ↵: the chosen menu row, or into the selected folder, or else what ⌘↵ does.
    private func submit(_ rows: [BrowsedFolder]) {
        if flow == .menu {
            let rows = menuRows
            if let selection, rows.indices.contains(selection) { go(rows[selection].flow) }
        } else if let selection, rows.indices.contains(selection) {
            enter(rows[selection].name)
        } else {
            primary()
        }
    }

    /// Tab: the selected folder, else one match, goes in; several extend to their common prefix.
    private func complete(_ rows: [BrowsedFolder]) -> KeyPress.Result {
        guard isBrowsing else { return .handled }
        if let selection, rows.indices.contains(selection) {
            enter(rows[selection].name)
        } else if let completion = PathCompletion.completion(rows.map(\.name), leaf: split.leaf) {
            if completion.isComplete { enter(completion.name) } else { text = split.directory + completion.name }
        }
        return .handled
    }

    private func enter(_ name: String) {
        text = split.directory + name + "/"
    }

    // MARK: Adding

    /// ⌘↵: Local folder adds the typed path; New project creates the named folder.
    private func primary() {
        guard !isWorking else { return }
        switch flow {
        case .menu:
            submit([])
        case .openFolder:
            let folder = PathCompletion.resolve(text, base: base)
            guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) else {
                error = "\(DisplayPath.abbreviated(folder)) doesn't exist."
                return
            }
            run { await model.openProject(at: folder) }
        case .newProject:
            let leaf = split.leaf.trimmingCharacters(in: .whitespaces)
            let parent = directory
            if leaf.isEmpty || leaf == "." || leaf == ".." {
                error = "Name the project first."
            } else if leaf.contains(":") {
                error = "A project name can't contain a colon."
            } else if !FileManager.default.fileExists(atPath: parent.path(percentEncoded: false)) {
                error = "\(DisplayPath.abbreviated(parent)) doesn't exist."
            } else if FileManager.default.fileExists(atPath: parent.appending(path: leaf).path(percentEncoded: false)) {
                error = "\(leaf) already exists in \(DisplayPath.abbreviated(parent))."
            } else {
                run { await model.createProject(at: parent.appending(path: leaf, directoryHint: .isDirectory)) }
            }
        }
    }

    private func run(_ work: @escaping @MainActor () async -> String?) {
        isWorking = true
        error = nil
        Task {
            let message = await work()
            isWorking = false
            error = message
        }
    }
}

private extension View {
    /// A palette row's height, padding and selected fill.
    func paletteRow(isSelected: Bool) -> some View {
        padding(.horizontal, 12)
            .frame(minHeight: 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Palette.rowCursor : .clear, in: .rect(cornerRadius: 8))
            .padding(.horizontal, 4)
            .contentShape(.rect)
    }
}

/// A folder the flow lists, marked when it holds a git repository.
struct BrowsedFolder: Identifiable, Hashable {
    let url: URL
    let isRepository: Bool

    var id: URL { url }
    var name: String { url.lastPathComponent }
}

enum FolderListing {
    /// Subfolders, hidden ones included, packages such as apps left out, sorted as Finder sorts
    /// them. A folder counts as a repository when it has a `.git`, except the privacy-guarded
    /// folders in a place that isn't guarded itself (Documents in your home), where looking would
    /// ask for access.
    static func subfolders(of folder: URL) -> [BrowsedFolder] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey]
        let contents = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys))) ?? []
        let parentGuarded = PrivacyCheck.isProtected(folder)
        return contents.compactMap { url -> BrowsedFolder? in
            let values = try? url.resolvingSymlinksInPath().resourceValues(forKeys: keys)
            guard values?.isDirectory == true, values?.isPackage != true else { return nil }
            let canLook = parentGuarded || !PrivacyCheck.isProtected(url)
            let isRepository = canLook && FileManager.default.fileExists(atPath: url.appending(path: ".git").path(percentEncoded: false))
            return BrowsedFolder(url: url, isRepository: isRepository)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
