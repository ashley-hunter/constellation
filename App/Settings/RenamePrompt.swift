import AppKit

/// A small modal with a text field. Its own window, so desktop keys don't reach the field.
@MainActor
enum RenamePrompt {
    /// The new name, or nil when cancelled, or left empty unless `allowsEmpty`.
    static func ask(_ title: String, current: String, allowsEmpty: Bool = false) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(string: current)
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty && !allowsEmpty ? nil : name
    }
}

extension AppModel {
    func renameSession(_ id: UUID, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, sessionsByID[id]?.title != title else { return }
        update(id) { $0.title = title }
    }

    func promptRenameSession(_ id: UUID) {
        guard let session = sessionsByID[id], let title = RenamePrompt.ask("Rename Session", current: session.title) else { return }
        renameSession(id, to: title)
    }
}
