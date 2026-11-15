import ConstellationCore
import SwiftUI

/// The split screen's empty slot while you pick what fills it, as Snap Assist does: an inset well
/// of the other sessions as small cards, those that need you first. Typing filters by title or
/// project, the arrows move the blue cursor, ↵ or a click picks, esc stops (see `goBack`).
struct GridSlotPicker: View {
    @Environment(AppModel.self) private var model
    /// Cards across: two in a wide slot, one in a narrow one.
    let columns: Int
    /// How many tiles are filled, so a pick that moves the slot on starts it afresh.
    let filled: Int
    @State private var query = ""
    @State private var cursor: UUID?
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        let sessions = model.gridCandidates(beside: nil, matching: query)
        let well = RoundedRectangle(cornerRadius: PanelSurface.cornerRadius, style: .continuous)
        VStack(spacing: 0) {
            field(sessions)
            list(sessions)
        }
        .padding(10)
        // The tiles' own glass, so the slot reads as one of them and the desktop's cards only blur
        // through, as they do behind the tiles.
        .background(PanelFill(shape: well))
        .overlay(well.strokeBorder(Palette.text.opacity(0.22), style: StrokeStyle(lineWidth: 1.5, dash: [7, 5])))
        // A new query starts the cursor at the top; otherwise it stays while its card is still listed.
        .onChange(of: CursorKey(query: query, ids: sessions.map(\.id)), initial: true) { old, new in
            if old.query != new.query { PointerHover.settle() }
            if old.query != new.query || !new.ids.contains(where: { $0 == cursor }) { cursor = new.ids.first }
        }
        .onChange(of: filled) {
            query = ""
            isFieldFocused = true
        }
        .task {
            PointerHover.settle()
            isFieldFocused = true
        }
    }

    private func field(_ sessions: [Session]) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.textTertiary)
            TextField(filled == 1 ? "Pick a session for this half" : "Pick a session for this tile", text: $query)
                .textFieldStyle(.plain)
                .font(.ui(13.5))
                .focused($isFieldFocused)
                .onSubmit { if let cursor { model.pickForGrid(cursor) } }
                .onKeyPress(.downArrow) { move(columns, in: sessions) }
                .onKeyPress(.upArrow) { move(-columns, in: sessions) }
                // Across only with two columns, so one column leaves them to the text.
                .onKeyPress(.rightArrow) { columns > 1 ? move(1, in: sessions) : .ignored }
                .onKeyPress(.leftArrow) { columns > 1 ? move(-1, in: sessions) : .ignored }
                .onKeyPress(.tab) { move(1, in: sessions) }
            KeyChip("esc")
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .panelSurface(.card, cornerRadius: Radius.inner)
        .padding(.bottom, 10)
    }

    @ViewBuilder private func list(_ sessions: [Session]) -> some View {
        if sessions.isEmpty {
            Text(query.isEmpty ? "Nothing else to add." : "Nothing matches \u{201C}\(query)\u{201D}.")
                .font(.ui(13))
                .foregroundStyle(Palette.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: columns), spacing: 10) {
                        ForEach(sessions) { session in
                            GridPickCard(session: session, isCursor: cursor == session.id)
                                .id(session.id)
                                .onTapGesture { model.pickForGrid(session.id) }
                                .onContinuousHover { phase in
                                    if case .active = phase, PointerHover.moved() { cursor = session.id }
                                }
                        }
                    }
                    // Room for the cursor's ring, which is drawn outside the card.
                    .padding(6)
                }
                .scrollIndicators(.never)
                .padding(-6)
                .onChange(of: cursor) { _, id in
                    if let id { withAnimation(.hover) { proxy.scrollTo(id) } }
                }
            }
        }
    }

    private func move(_ offset: Int, in sessions: [Session]) -> KeyPress.Result {
        guard !sessions.isEmpty else { return .ignored }
        PointerHover.settle()
        let index = sessions.firstIndex { $0.id == cursor }.map { $0 + offset } ?? 0
        cursor = sessions[min(max(index, 0), sessions.count - 1)].id
        return .handled
    }
}

/// A session in the picker: its state, project and title, and one line of what it's doing.
private struct GridPickCard: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let isCursor: Bool

    var body: some View {
        let project = model.project(session.projectID)
        let summary = TileSummary(session: session, output: model.output(for: session.id), hasPullRequest: false)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                RunGlyph(runState: session.runState)
                if let project { ProjectMark(project: project) }
                Text(session.title)
                    .font(.ui(13, weight: .medium))
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if session.runState == .blocked {
                    Circle().fill(Palette.ask).frame(width: 6, height: 6)
                        .accessibilityLabel("Needs you")
                }
            }
            Text(summary.lines.0)
                .font(.ui(12))
                .foregroundStyle(summary.primaryColor == Palette.text ? Palette.textSecondary : summary.primaryColor)
                .lineLimit(1)
            if let project {
                Text(project.name)
                    .font(.ui(11))
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isCursor ? Palette.card : Palette.popover, in: .rect(cornerRadius: Radius.inner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.inner, style: .continuous).strokeBorder(Palette.edge))
        .overlay(FocusRing(cornerRadius: Radius.inner, isOn: isCursor))
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// What the cursor follows: the query and the cards it lists.
private struct CursorKey: Equatable {
    let query: String
    let ids: [UUID]
}
