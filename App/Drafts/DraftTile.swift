import ConstellationCore
import SwiftUI

/// A draft in its pile: a card like any other, a shade lighter, titled with the first line of what
/// you have written so far, the rest under it. ↵, a double-click or typing opens it again.
struct DraftTile: View {
    @Environment(AppModel.self) private var model
    @Environment(\.cardSize) private var size
    let session: Session
    let project: Project?

    var body: some View {
        let draft = model.chatDraft(for: session.id)
        let (title, rest) = Self.split(draft.text)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.icon)
                    .frame(width: 12)
                if let project { ProjectMark(project: project) }
                Text(title ?? "New session")
                    .font(.ui(13, weight: .medium))
                    .foregroundStyle(title == nil ? Palette.textSecondary : Palette.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .frame(height: TileMetrics.titleBarHeight)

            if let rest {
                Text(rest)
                    .font(.ui(13))
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(3)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
            }

            if !draft.attachments.isEmpty {
                Label("\(draft.attachments.count) attached", systemImage: "paperclip")
                    .font(.ui(12))
                    .foregroundStyle(Palette.textTertiary)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
            }
            Spacer(minLength: 0)
            Text("Draft · \(modelTitle)")
                .font(.ui(12))
                .foregroundStyle(Palette.textTertiary)
                .lineLimit(1)
                // Where a session card's footer status sits.
                .padding(.leading, 12)
                .frame(height: TileAction.height)
                .padding(.bottom, TileAction.cornerInset)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        // A touch of frost over the card fill, so a draft reads as not started yet.
        .background(Palette.text.opacity(0.04))
        .panelSurface(.card)
        // While its panel is open the panel is this tile, opened; two copies would read as two drafts.
        // An empty one closed with esc stays hidden until it's thrown away.
        .opacity(isHidden ? 0 : 1)
        .animation(.constellation, value: isHidden)
    }

    private var isHidden: Bool {
        model.openedSessionID == session.id || model.discardingDraftID == session.id
    }

    private var modelTitle: String {
        model.modelChoices(for: session.provider).first { $0.id == session.model }?.title
            ?? (session.model.isEmpty ? "default" : session.model)
    }

    /// The brief's first non-empty line, and what follows it, each nil when there's nothing.
    static func split(_ text: String) -> (title: String?, rest: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (nil, nil) }
        let lines = trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let rest = lines.count > 1 ? lines[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return (lines[0].trimmingCharacters(in: .whitespaces), rest.isEmpty ? nil : rest)
    }
}

/// A draft's context menu: open it, start it, or throw it away.
struct DraftTileMenu: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        Button("Open") { model.openSession(session.id) }
        ActionButton(.draftStart, on: .session(session.id))
        Divider()
        ActionButton(.draftDiscard, on: .session(session.id))
    }
}
