import SwiftUI

/// A terminal's live shell view in SwiftUI. Clicking it gives it the keyboard; `takesFocus` does
/// that as soon as it appears. An inert one, a tile's, never takes the keyboard or the mouse.
struct TerminalSurface: NSViewRepresentable {
    @Environment(AppModel.self) private var model
    let terminalID: UUID
    var fontSize: CGFloat = 12
    var takesFocus = false
    var isInert = false

    func makeNSView(context: Context) -> TerminalHolder {
        let holder = TerminalHolder(fontSize: fontSize, takesFocus: takesFocus, isInert: isInert)
        let (id, host) = (terminalID, model.terminalHost)
        holder.onDismantle = { [weak holder] in
            guard let holder else { return }
            host.detach(holder, from: id)
        }
        model.attachTerminal(holder, to: terminalID)
        return holder
    }

    func updateNSView(_ holder: TerminalHolder, context: Context) {
        holder.fontSize = fontSize
        holder.takesFocus = takesFocus
        holder.isInert = isInert
    }

    static func dismantleNSView(_ holder: TerminalHolder, coordinator: ()) {
        holder.onDismantle?()
    }
}
