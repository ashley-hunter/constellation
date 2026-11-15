import ConstellationCore
import SwiftUI

/// The open draft: where it runs (project, branch, worktree) on one quiet line, then the composer
/// for the first message, with the model and effort in it and permission beneath.
/// Everything stays editable until it starts. esc or a click outside closes it.
struct DraftPanel: View {
    @Environment(AppModel.self) private var model
    let session: Session
    @State private var branches: [String] = []

    static let width: CGFloat = 640

    var body: some View {
        let project = model.project(session.projectID)
        VStack(alignment: .leading, spacing: 0) {
            place(project)
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .arrowCursor()
            ChatComposer(session: session, style: .draft, focusOnAppear: true)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 12)
            if model.draftIsPlacedAsQuestion(session.id) {
                Text("A question, so it runs in the project folder. \(model.binding(for: .draftWorktree)?.label ?? "⌥W") for a worktree.")
                    .font(.ui(12))
                    .foregroundStyle(Palette.textTertiary)
                    .padding(.horizontal, 16)
                    .padding(.top, -6)
                    .padding(.bottom, 10)
            }
        }
        .frame(width: Self.width)
        .panelSurface()
        .onDrop(of: AppModel.droppableTypes, isTargeted: nil) { providers in
            model.acceptDrop(providers, onto: session.id, onTile: false)
        }
        .task(id: session.projectID) { branches = await model.baseBranchChoices(for: session) }
        .task { for provider in Provider.allCases { await model.loadModelChoices(for: provider) } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("New session in \(project?.name ?? "project")")
    }

    private func place(_ project: Project?) -> some View {
        HStack(spacing: 2) {
            picker(help: "Project") {
                ForEach(model.projects) { project in
                    check(project.name, isOn: project.id == session.projectID) { model.moveDraft(session.id, to: project.id) }
                }
            } label: {
                QuietChip(title: project?.name ?? "Project", swatch: project?.swatch, isProminent: true)
            }
            picker(help: "Where it runs") {
                check("New worktree", isOn: session.usesWorktree) { model.setDraftWorktree(session.id, true) }
                check("In the project folder", isOn: !session.usesWorktree) { model.setDraftWorktree(session.id, false) }
            } label: {
                QuietChip(title: session.usesWorktree ? "New worktree" : "In the project folder", systemImage: session.usesWorktree ? "square.stack" : "folder")
            }
            if session.usesWorktree {
                picker(help: "The branch the new worktree starts from") {
                    ForEach(branches.isEmpty ? [session.baseBranch] : branches, id: \.self) { branch in
                        check(branch, isOn: branch == session.baseBranch) { model.setDraftBaseBranch(session.id, branch) }
                    }
                } label: {
                    QuietChip(title: "from \(session.baseBranch)", systemImage: "arrow.triangle.branch")
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func picker<Items: View, Label: View>(help: String, @ViewBuilder items: () -> Items, @ViewBuilder label: () -> Label) -> some View {
        Menu(content: items, label: label)
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(help)
    }

    private func check(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if isOn { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }
}

/// An open draft over the desktop. `DesktopOverlays` pops it in, with its scrim, when it has one,
/// beside it so the scrim only fades and never scales with the panel.
struct DraftOverlay: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let morph: Namespace.ID

    var body: some View {
        GeometryReader { proxy in
            DraftPanel(session: session)
                .matchedGeometryEffect(id: session.id, in: morph)
                .padding(.top, max(40, proxy.size.height * 0.2))
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
    }
}

enum DisplayPath {
    /// A folder with the home directory shown as ~.
    static func abbreviated(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        let home = NSHomeDirectory()
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        return trimmed.hasPrefix(home) ? "~" + trimmed.dropFirst(home.count) : trimmed
    }
}
