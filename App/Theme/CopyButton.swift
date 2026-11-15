import AppKit
import SwiftUI

/// A small copy icon that turns into a tick for a moment after copying.
struct CopyButton: View {
    let text: String
    var help = "Copy"
    /// Raised over content it sits on, such as a code block; flat in a row of actions.
    var isRaised = false
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
        } label: {
            // Says Copied for a moment, so you know it worked.
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                if copied { Text("Copied").font(.ui(12)) }
            }
            .foregroundStyle(copied ? AnyShapeStyle(Palette.done) : AnyShapeStyle(.foreground))
            .padding(.horizontal, copied ? 6 : 0)
            .frame(minWidth: 24, minHeight: 24)
        }
        .buttonStyle(IconButtonStyle(width: nil, height: 24, isRaised: isRaised))
        .help(copied ? "Copied" : help)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

extension View {
    /// Shows a copy button in a corner while the pointer is over the view.
    func copyable(_ text: String, alignment: Alignment = .topTrailing, help: String = "Copy") -> some View {
        modifier(Copyable(text: text, alignment: alignment, help: help))
    }
}

private struct Copyable: ViewModifier {
    let text: String
    let alignment: Alignment
    let help: String
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: alignment) {
                if isHovered, !text.isEmpty { CopyButton(text: text, help: help, isRaised: true).padding(4).transition(.opacity) }
            }
            .onHover { isHovered = $0 }
            .animation(.hover, value: isHovered)
    }
}
