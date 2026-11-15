import ConstellationCore
import Foundation

/// A name you give a worktree to say what the work is, shown on its pile's label in place of the
/// branch. Only Constellation knows it: the folder and branch keep theirs.
extension AppModel {
    /// As JSON: `{"<folder>": "Checkout redesign"}`.
    static let worktreeNamesKey = "worktrees.names"

    func worktreeName(of folder: String) -> String? {
        worktreeNames[folder]
    }

    /// The worktree a session runs in, nil when it runs in its project's checkout.
    func worktreeFolder(of session: Session) -> String? {
        session.usesWorktree ? Piles.folder(session.worktreePath) : nil
    }

    /// Names the worktree, or clears its name when the name is empty.
    func renameWorktree(_ folder: String, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard worktreeNames[folder] != name, !(name.isEmpty && worktreeNames[folder] == nil) else { return }
        worktreeNames[folder] = name.isEmpty ? nil : name
        saveWorktreeNames()
    }

    func promptRenameWorktree(_ folder: String) {
        let current = worktreeNames[folder] ?? ""
        guard let name = RenamePrompt.ask("Rename Worktree", current: current, allowsEmpty: true) else { return }
        renameWorktree(folder, to: name)
    }

    func forgetWorktreeName(_ folder: String) {
        guard worktreeNames.removeValue(forKey: folder) != nil else { return }
        saveWorktreeNames()
    }

    /// Reads the names, dropping those of worktrees no session or terminal is in any more.
    func restoreWorktreeNames() {
        guard let text = (try? services.store.setting(Self.worktreeNamesKey)) ?? nil,
              let names = try? JSONDecoder().decode([String: String].self, from: Data(text.utf8)) else { return }
        let live = Set(sessionsByID.values.map { Piles.folder($0.worktreePath) } + terminalsByID.values.map { Piles.folder($0.workingDirectory) })
        worktreeNames = names.filter { live.contains($0.key) }
        if worktreeNames.count != names.count { saveWorktreeNames() }
    }

    private func saveWorktreeNames() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let text = worktreeNames.isEmpty ? nil : (try? encoder.encode(worktreeNames)).flatMap { String(data: $0, encoding: .utf8) }
        saveSetting(Self.worktreeNamesKey, text)
    }
}
