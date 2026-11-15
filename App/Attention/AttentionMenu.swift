import ConstellationCore
import SwiftUI

/// The menu bar extra's title: ◆ and the blocked count.
struct AttentionMenuLabel: View {
    let model: AppModel

    var body: some View {
        Text("\(Glyph.blocked) \(model.blockedCount)")
            .accessibilityLabel("\(model.blockedCount) blocked")
    }
}

/// Blocked and failed sessions; choosing one focuses its tile.
struct AttentionMenu: View {
    let model: AppModel

    var body: some View {
        let (blocked, failed) = model.sessionsNeedingYou
        Text(blocked.count == 1 ? "1 blocked" : "\(blocked.count) blocked")
        if !blocked.isEmpty {
            Section("Needs you") {
                ForEach(blocked) { session in
                    row(session, detail: session.nextAsk?.kind.headline)
                }
            }
        }
        if !failed.isEmpty {
            Section("Failed") {
                ForEach(failed) { session in
                    row(session, detail: session.failureMessage)
                }
            }
        }
        Divider()
        Button("Show Desktop") { AppModel.bringDesktopForward() }
        Button("Quit Constellation") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func row(_ session: Session, detail: String?) -> some View {
        let project = model.project(session.projectID)?.name
        let title = [project, session.title].compactMap(\.self).joined(separator: " / ")
        let glyph = session.runState == .blocked ? Glyph.blocked : Glyph.failed
        return Button {
            model.reveal(.session(session.id))
        } label: {
            Text("\(glyph) \(title)")
            if let detail { Text(detail) }
        }
    }
}
