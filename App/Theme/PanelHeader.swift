import SwiftUI

/// The one quiet line at the top of an opened panel (the session view, the opened terminal): what
/// it is on the left, which alone gives way when space is short, and borderless controls on the
/// right that never truncate. No fill and no divider; it sits straight on the panel surface.
struct PanelHeader<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) { leading }
            Spacer(minLength: 8)
            HStack(spacing: 2) { trailing }
                .fixedSize()
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .frame(height: 48)
    }
}

/// The header's Back, closing the panel back into its card. Its key is in the tooltip.
struct PanelBackButton: View {
    @Environment(AppModel.self) private var model
    /// Esc; ⌘M over a terminal, whose shell keeps esc.
    var key: String? = "esc"

    var body: some View {
        Button { model.perform(.back) } label: {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(IconButtonStyle())
        .help(key.map { "Back to the desktop (\($0))" } ?? "Back to the desktop")
        .accessibilityLabel("Back to the desktop")
    }
}

/// The header's … menu, holding everything that isn't worth a control of its own.
struct PanelOverflowMenu<Content: View>: View {
    let help: String
    @ViewBuilder var content: Content

    var body: some View {
        Menu {
            content
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.button)
        .buttonStyle(IconButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help)
    }
}
