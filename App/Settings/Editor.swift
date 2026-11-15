import AppKit
import ConstellationCore
import SwiftUI

/// Apps a worktree can be opened in. Only the installed ones are offered.
enum Editor: String, CaseIterable, Identifiable, Sendable {
    case vsCode, cursor, zed, xcode, finder, terminal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .vsCode: "VS Code"
        case .cursor: "Cursor"
        case .zed: "Zed"
        case .xcode: "Xcode"
        case .finder: "Finder"
        case .terminal: "Terminal"
        }
    }

    private var bundleIdentifier: String {
        switch self {
        case .vsCode: "com.microsoft.VSCode"
        case .cursor: "com.todesktop.230313mzl4w4u92"
        case .zed: "dev.zed.Zed"
        case .xcode: "com.apple.dt.Xcode"
        case .finder: "com.apple.finder"
        case .terminal: "com.apple.Terminal"
        }
    }

    var applicationURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    /// Looked up once; installing an editor shows up on the next launch.
    static let installed: [Editor] = allCases.filter { $0 == .finder || $0.applicationURL != nil }

    @MainActor var icon: NSImage {
        let icon = applicationURL.map { NSWorkspace.shared.icon(forFile: $0.path(percentEncoded: false)) } ?? NSImage()
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }

    @MainActor func open(_ folder: URL) {
        guard self != .finder, let app = applicationURL else {
            NSWorkspace.shared.open(folder)
            return
        }
        NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}

extension AppModel {
    /// Opens the session's worktree in `editor`, or the remembered one. Picking one remembers it.
    func openInEditor(_ sessionID: UUID, editor: Editor? = nil) {
        guard let session = sessionsByID[sessionID] else { return }
        let folder = session.worktreePath
        guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) else {
            notice = "\(session.title)'s worktree is gone, so there is nothing to open."
            return
        }
        openFolder(folder, in: editor)
    }

    /// Opens `folder` in `editor`, or the remembered one. Picking one remembers it.
    func openFolder(_ folder: URL, in editor: Editor? = nil) {
        if let editor { settings.editor = editor }
        (editor ?? settings.preferredEditor).open(folder)
    }
}

/// "Open in Cursor" with a menu of the other installed editors.
struct OpenInEditorButton: View {
    @Environment(AppModel.self) private var model
    let sessionID: UUID

    var body: some View {
        let preferred = model.settings.preferredEditor
        Menu {
            OpenInEditorItems(sessionID: sessionID)
        } label: {
            Label { Text("Open in \(preferred.title)") } icon: { Image(nsImage: preferred.icon) }
                .labelStyle(.titleAndIcon)
                .font(.ui(13, weight: .medium))
        } primaryAction: {
            model.perform(.sessionOpenInEditor, on: .session(sessionID))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .padding(.horizontal, 10)
        .frame(height: 30)
        .foregroundStyle(Palette.text)
        .background(Palette.surfaceRaised, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.text.opacity(0.14)))
        .help("Open the worktree in \(preferred.title). The arrow picks another editor.")
    }
}

/// One item per installed editor, for the button's menu and the tile menu.
struct OpenInEditorItems: View {
    @Environment(AppModel.self) private var model
    let sessionID: UUID

    var body: some View {
        ForEach(Editor.installed) { editor in
            Button {
                model.perform(.sessionOpenInEditor, on: .session(sessionID), argument: editor.rawValue)
            } label: {
                Label { Text(editor.title) } icon: { Image(nsImage: editor.icon) }
            }
        }
    }
}
