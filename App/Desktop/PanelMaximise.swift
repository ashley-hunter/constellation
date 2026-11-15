import ConstellationCore
import SwiftUI

/// An opened panel that can fill the desktop. Each kind remembers whether it was maximised, for as
/// long as the app runs.
enum PanelKind: Hashable {
    case session, terminal, browser, note

    init(_ terminal: Terminal) {
        self = switch terminal.kind {
        case .browser: .browser
        case .note: .note
        case .shell, .task: .terminal
        }
    }
}

extension AppModel {
    /// The opened panel's kind: a session (not a draft), a terminal, a browser or a note.
    var openedPanelKind: PanelKind? {
        switch openedTile {
        case .session(let id)?: sessionsByID[id]?.isDraft == false ? .session : nil
        case .terminal(let id)?: terminalsByID[id].map(PanelKind.init) ?? .terminal
        case nil: nil
        }
    }

    func isMaximised(_ kind: PanelKind?) -> Bool {
        kind.map(maximisedPanels.contains) ?? false
    }

    /// The opened panel fills the desktop, or goes back to its own size, on the panel's spring.
    func toggleMaximised() {
        guard let kind = openedPanelKind else { return }
        withAnimation(.present) {
            if maximisedPanels.contains(kind) {
                maximisedPanels.remove(kind)
            } else {
                maximisedPanels.insert(kind)
            }
        }
    }

    /// Where a maximised panel sits in a container of `size`: the whole desktop 16 points in, beside
    /// the sidebar when it shows.
    func maximisedFrame(in size: CGSize) -> CGRect {
        let left = !showsLauncher && isSidebarShown ? DesktopGeometry.sidebarClearance : 16
        return CGRect(x: left, y: 16, width: max(size.width - left - 16, 0), height: max(size.height - 32, 0))
    }
}

extension ActionID {
    static let panelMaximise: ActionID = "panel.maximise"
}

extension ActionRegistry {
    static var panelActions: [PaletteAction] {
        [
            PaletteAction(
                id: .panelMaximise, title: "Maximise", keywords: ["maximize", "zoom", "fill", "full", "bigger", "restore", "smaller", "panel"],
                systemImage: "arrow.up.left.and.arrow.down.right",
                label: { context in context.model.isMaximised(context.model.openedPanelKind) ? "Restore" : "Maximise" },
                section: .command,
                keys: [KeyBinding("cmd+shift+m")],
                isAvailable: { context, _ in context.model.openedPanelKind != nil },
                unavailableReason: "Open a session, terminal, browser or note first",
                perform: { context, _ in context.model.toggleMaximised() }
            ),
        ]
    }
}

/// The opened panel's header button that maximises it or restores it, before its … menu.
struct PanelMaximiseButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let isMaximised = model.isMaximised(model.openedPanelKind)
        let key = model.binding(for: .panelMaximise).map { " (\($0.label))" } ?? ""
        Button { model.perform(.panelMaximise) } label: {
            Image(systemName: isMaximised ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 11, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(IconButtonStyle())
        .help((isMaximised ? "Restore" : "Maximise") + key)
        .accessibilityLabel(isMaximised ? "Restore" : "Maximise")
    }
}
