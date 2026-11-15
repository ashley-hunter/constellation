import ConstellationCore
import SwiftUI

/// A menu item or button that runs a registered action: its title, icon and ⌘ shortcut come from
/// the registry, and it greys out when the action can't run.
struct ActionButton: View {
    @Environment(AppModel.self) private var model
    let id: ActionID
    var item: TileItem?
    var argument: String?
    var title: String?
    var showsIcon = false

    init(_ id: ActionID, on item: TileItem? = nil, argument: String? = nil, title: String? = nil, showsIcon: Bool = false) {
        self.id = id
        self.item = item
        self.argument = argument
        self.title = title
        self.showsIcon = showsIcon
    }

    var body: some View {
        let action = ActionRegistry.action(id)
        let context = model.actionContext(on: item, via: .menu)
        let label = title ?? action?.title(in: context) ?? id.rawValue
        Button {
            model.perform(id, on: item, argument: argument)
        } label: {
            if showsIcon, let image = action?.systemImage { Label(label, systemImage: image) } else { Text(label) }
        }
        .disabled(action?.canRun(context, argument: argument) != true)
        .keyboardShortcut(model.menuShortcut(for: id, argument: argument)?.keyboardShortcut)
    }
}
