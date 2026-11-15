import ConstellationCore
import SwiftUI

/// A terminal on the desktop, in the session tiles' language: one continuous card with a quiet
/// title line and a live mini view of the shell below it, spacing rather than rules between them.
/// The shell here is only shown: the tile takes desktop focus like any other, and ↵, space or a
/// double-click opens the larger view, which has the keyboard.
struct TerminalTile: View {
    @Environment(AppModel.self) private var model
    @Environment(\.cardSize) private var size
    let terminal: Terminal
    let project: Project?
    /// Off behind another card or shrunk into the strip: the title only, and no live shell to draw.
    var isLive = true

    var body: some View {
        let isFocused = model.focusedItem == .terminal(terminal.id)
        VStack(alignment: .leading, spacing: 0) {
            TerminalTitleBar(terminal: terminal, project: project)
            if let command = terminal.command, let phase = model.taskPhase(of: terminal) {
                TaskFace(task: terminal, command: command, phase: phase, isLive: isLive)
            } else {
                shell
            }
        }
        .frame(width: size.width, height: size.height)
        .panelSurface(.card, edge: isFocused ? Palette.edge : TerminalStateStyle.border(for: terminal, phase: model.taskPhase(of: terminal)))
        .contextMenu {
            ActionButton(.tileOpen, on: .terminal(terminal.id), title: "Open")
            if terminal.isTask {
                ActionButton(.taskRestart, on: .terminal(terminal.id))
                ActionButton(.taskStop, on: .terminal(terminal.id))
            }
            ActionButton(.terminalClose, on: .terminal(terminal.id))
        }
    }

    private var shell: some View {
            Group {
                if isLive {
                    TerminalSurface(terminalID: terminal.id, fontSize: 9, isInert: true)
                        .id(terminal.id)
                } else {
                    Color.clear
                }
            }
            // The session tile's summary inset.
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A task's card below its title. Not running: its command where a shell's prompt would be, then how
/// the last run went, with the lines that say why if it failed. Running: its output, a link to the
/// dev server it started, and the command quietly at the foot.
private struct TaskFace: View {
    @Environment(AppModel.self) private var model
    let task: Terminal
    let command: String
    let phase: TaskPhase
    let isLive: Bool

    private var isRunning: Bool {
        if case .running = phase { true } else { false }
    }

    private var server: URL? {
        if case .running(let server) = phase { server } else { nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isRunning {
                if let server {
                    Button { model.openBrowser(projectID: task.projectID, url: server) } label: {
                        Label(server.host().map { "\($0):\(server.port ?? 80)" } ?? server.absoluteString, systemImage: "globe")
                            .font(.ui(11.5))
                            .foregroundStyle(Palette.focus)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help("Open \(server.absoluteString) in a browser")
                }
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                Text(command).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Palette.textTertiary).lineLimit(1)
            } else {
                HStack(spacing: 6) {
                    Text("$").foregroundStyle(Palette.textTertiary)
                    Text(command).foregroundStyle(Palette.text).lineLimit(1).truncationMode(.middle)
                }
                .font(.system(size: 11.5, design: .monospaced))
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(Palette.text.opacity(0.06), in: .rect(cornerRadius: 6))
                lastRun
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Always there, as the shell only starts once its grid has a size; shown only while the
        // command runs, between the address and the command.
        .background {
            if isLive {
                TerminalSurface(terminalID: task.id, fontSize: 9, isInert: true)
                    .id(task.id)
                    .padding(.horizontal, 12)
                    .padding(.top, server == nil ? 6 : 26)
                    .padding(.bottom, 26)
                    .opacity(isRunning ? 1 : 0)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder private var lastRun: some View {
        switch phase {
        case .failed(_, _, let lines):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    Text(line).foregroundStyle(index == 0 ? Palette.error : Palette.textSecondary).lineLimit(1)
                }
            }
            .font(.system(size: 10.5, design: .monospaced))
        default:
            Text(summary).font(.ui(11.5)).foregroundStyle(Palette.textTertiary)
        }
    }

    private var summary: String {
        switch phase {
        case .notRun: "Not run yet. Run starts it here."
        case .starting, .running: "Starting…"
        case .succeeded(let at): "Last run \(at.formatted(.relative(presentation: .named))) · finished cleanly"
        case .stopped(let at?): "Last run \(at.formatted(.relative(presentation: .named))) · stopped"
        case .stopped(nil): "Stopped"
        case .failed: ""
        }
    }
}

/// Glyph, swatch and name, and running, idle or the last exit code quietly on the right, as a
/// session tile's title line.
struct TerminalTitleBar: View {
    @Environment(AppModel.self) private var model
    let terminal: Terminal
    let project: Project?
    /// Over a browser's page: its tone, so the title takes the colours that read on it.
    var tone: WallpaperTone?

    var body: some View {
        HStack(spacing: 8) {
            TerminalGlyph(state: terminal.state, kind: terminal.kind, tone: tone)
            if let project { ProjectMark(project: project) }
            // A note is named by its first line, and quietly untitled until it has one.
            let isUntitled = terminal.isNote && terminal.title.isEmpty
            Text(model.displayTitle(of: terminal))
                .font(.ui(13, weight: .medium))
                .foregroundStyle(isUntitled ? tone?.secondaryText ?? Palette.textSecondary : tone?.primaryText ?? Palette.text)
                .lineLimit(1)
            Spacer(minLength: 4)
            let phase = model.taskPhase(of: terminal)
            if let label = TerminalStateStyle.label(for: terminal, phase: phase) {
                Text(label)
                    .font(.ui(12))
                    .foregroundStyle(TerminalStateStyle.quietColor(for: terminal, phase: phase))
                    .lineLimit(1)
            }
            if let phase { TaskButton(task: terminal, phase: phase) }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .frame(height: TileMetrics.titleBarHeight)
        .contentShape(.rect)
    }
}

/// ⠹ while a command runs or a page loads; idle, a prompt mark for a shell or a task, a globe for a
/// browser, or a page for a note.
struct TerminalGlyph: View {
    let state: Terminal.State
    let kind: Terminal.Kind
    var tone: WallpaperTone?

    var body: some View {
        Group {
            switch state {
            case .running: BrailleSpinner(color: tone == .light ? WallpaperTone.light.secondaryText : Palette.working)
            case .idle: Image(systemName: symbol).font(.system(size: 10, weight: .medium)).foregroundStyle(tone?.secondaryText ?? Palette.textTertiary)
            }
        }
        .frame(width: 12)
        .accessibilityLabel(state == .running ? (kind == .browser ? "Loading" : "Running") : "Idle")
    }

    private var symbol: String {
        switch kind {
        case .browser: "globe"
        case .note: "note.text"
        case .shell, .task: "terminal"
        }
    }
}

/// A terminal's state on its title line, panel header and card edge. A task passes its phase
/// (``AppModel/taskPhase(of:)``); a plain shell passes nil and is read from its last command.
enum TerminalStateStyle {
    /// Only a failed last command earns words; running shows as the spinning glyph, and idle as
    /// nothing. A task also says Starting and Done; its Run, Restart or Stop button tells the rest.
    static func label(for terminal: Terminal, phase: TaskPhase?) -> String? {
        switch phase {
        case .starting?: return "Starting…"
        case .succeeded?: return "Done"
        case .failed(let code, _, _)?: return "exit \(code)"
        case .notRun?, .running?, .stopped?: return nil
        case nil:
            guard isFailed(terminal, phase: nil), let code = terminal.lastExitCode else { return nil }
            return "exit \(code)"
        }
    }

    /// The last command failed. A shell's ⌃C (130) counts; a task's is stopping it (see ``TaskPhase``).
    static func isFailed(_ terminal: Terminal, phase: TaskPhase?) -> Bool {
        if let phase {
            if case .failed = phase { return true }
            return false
        }
        guard terminal.state == .idle, let code = terminal.lastExitCode else { return false }
        return code != 0
    }

    /// Tertiary, as quiet chrome is, unless the last command failed.
    static func quietColor(for terminal: Terminal, phase: TaskPhase?) -> Color {
        isFailed(terminal, phase: phase) ? Palette.error : Palette.textTertiary
    }

    static func border(for terminal: Terminal, phase: TaskPhase?) -> Color {
        isFailed(terminal, phase: phase) ? Palette.error.opacity(0.35) : .white.opacity(0.12)
    }
}

/// A task's one action, beside its state: Stop while it starts or runs, else Run, or Restart once it has.
struct TaskButton: View {
    @Environment(AppModel.self) private var model
    let task: Terminal
    let phase: TaskPhase

    var body: some View {
        // Focused too, so the key shown on the button acts on this card next time.
        if phase.isActive {
            TileAction(title: "Stop", systemImage: "stop.fill", key: "⌘.") {
                model.focus(.terminal(task.id))
                model.stopTask(task.id)
            }
        } else {
            TileAction(title: phase == .notRun ? "Run" : "Restart", systemImage: "play.fill", key: "⌘R") {
                model.focus(.terminal(task.id))
                model.restartTask(task.id)
            }
        }
    }
}
