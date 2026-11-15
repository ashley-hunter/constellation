import AppKit
import ConstellationCore
import SwiftUI

/// Settings > Keyboard: a full editor for keys.conf. Every change is written to the file straight
/// away, and hand edits to the file show up here.
struct KeyboardSettings: View {
    let model: AppModel
    @State private var search = ""
    @State private var recorder = KeyRecorder()

    private var keyboard: KeyboardController { model.keyboard }
    private var defaults: KeymapDefaults { KeyboardController.defaults }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !keyboard.keymap.problems.isEmpty { problems }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Bindings").font(.headline)
                    Spacer()
                    TextField("Search actions or keys", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }
                table(rows: filtered(bindingRows), global: false)
                    .frame(height: 260)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Global hotkeys").font(.headline)
                Text("Work from any app. No Accessibility permission needed.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                table(rows: globalRows, global: true)
                    .frame(height: 150)
            }
            HStack {
                Button("Open keys.conf") { NSWorkspace.shared.open(keyboard.url) }
                Text(SettingsPath.abbreviated(keyboard.url)).font(.footnote).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Reset All…", action: resetAll)
            }
        }
        .padding(20)
        .onDisappear { recorder.cancel() }
    }

    private var problems: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(keyboard.keymap.problems, id: \.self) { problem in
                Label("Line \(problem.line): \(problem.message)", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: Rows

    struct Row: Identifiable, Hashable {
        let action: String
        let argument: String?
        let global: Bool
        let title: String
        var section: String?
        var id: String { "\(global ? "global:" : "")\(action):\(argument ?? "")" }
    }

    /// One row per action, or per argument for actions bound with one (each direction, each digit).
    private var bindingRows: [Row] {
        let context = model.actionContext(via: .menu)
        let local = defaults.bindings + keyboard.keymap.bindings.map(\.rule)
        // Moving around and making things first, then app commands, then what acts on a session.
        let sections: [(PaletteAction.Section, String)] = [(.navigation, "Navigation"), (.command, "Commands"), (.session, "Session")]
        let actions = sections.flatMap { section, _ in ActionRegistry.all.filter { $0.section == section } }
        return actions.filter { $0.id != .appSummon && $0.id != .appSummonBlocked }.flatMap { action in
            var arguments: [String?] = []
            for rule in local where rule.action == action.id.rawValue && !arguments.contains(rule.argument) {
                arguments.append(rule.argument)
            }
            if arguments.isEmpty { arguments = [nil] }
            let title = action.title(in: context).replacingOccurrences(of: "…", with: "")
            return arguments.map { argument in
                Row(
                    action: action.id.rawValue, argument: argument, global: false, title: argument.map { "\(title) \($0)" } ?? title,
                    section: sections.first { $0.0 == action.section }?.1
                )
            }
        }
    }

    private var globalRows: [Row] {
        var seen: Set<String> = []
        return (defaults.globals + keyboard.keymap.globals.map(\.rule)).compactMap { rule in
            let row = Row(action: rule.action, argument: rule.argument, global: true, title: Self.globalTitle(rule))
            return seen.insert(row.id).inserted ? row : nil
        }
    }

    private static func globalTitle(_ rule: KeyRule) -> String {
        let title = ActionRegistry.action(ActionID(rawValue: rule.action))?.title ?? rule.action
        return rule.argument.map { "\(title) \($0)" } ?? title
    }

    private func filtered(_ rows: [Row]) -> [Row] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return rows }
        return rows.filter { row in
            row.title.lowercased().contains(query) || row.action.contains(query)
                || keys(of: row).contains { $0.label.lowercased().contains(query) }
        }
    }

    private func keys(of row: Row) -> [KeyBinding] {
        keyboard.keymap.entries(for: row.action, argument: row.argument, global: row.global).map(\.rule.binding)
    }

    // MARK: Table

    private func table(rows: [Row], global: Bool) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if let section = row.section, index == 0 || rows[index - 1].section != section {
                        Text(section)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.top, index == 0 ? 6 : 12)
                            .padding(.bottom, 4)
                    }
                    rowView(row)
                    Divider().opacity(0.5)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
    }

    @ViewBuilder private func rowView(_ row: Row) -> some View {
        let keys = keys(of: row)
        let isCustomized = keyboard.keymap.isCustomized(row.action, argument: row.argument, global: row.global, defaults: defaults)
        let isRecording = recorder.target == row
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if row.global {
                    Toggle("", isOn: enabled(row, hasKeys: !keys.isEmpty)).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                }
                Text(row.title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                RecordButton(
                    bindings: keys,
                    isRecording: isRecording,
                    start: { record(row) }
                )
                Text(isCustomized ? "keys.conf" : "default")
                    .font(.footnote)
                    .foregroundStyle(isCustomized ? Color.accentColor : .secondary)
                    .frame(width: 60, alignment: .leading)
                Button { set([], for: row) } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless)
                    .help("Unbind")
                    .opacity(keys.isEmpty ? 0 : 1)
                    .disabled(keys.isEmpty)
                Button { keyboard.edit(model: model) { $0.reset(row.action, argument: row.argument, global: row.global, defaults: defaults) } } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .help("Reset to the default")
                .opacity(isCustomized ? 1 : 0)
                .disabled(!isCustomized)
            }
            if let conflict = recorder.conflict, conflict.row == row {
                conflictView(conflict)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .contentShape(.rect)
        .onTapGesture { record(row) }
    }

    private func conflictView(_ conflict: KeyRecorder.Conflict) -> some View {
        let names = conflict.others.map { entry in
            let title = ActionRegistry.action(ActionID(rawValue: entry.rule.action))?.title ?? entry.rule.action
            return entry.rule.argument.map { "\(title) \($0)" } ?? title
        }
        return HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("\(KeyBinding(strokes: conflict.strokes).label) is used by \(ListFormatter.localizedString(byJoining: names)).")
                .font(.footnote)
            Spacer()
            Button("Replace") { replace(conflict) }.controlSize(.small)
            Button("Cancel") { recorder.conflict = nil }.controlSize(.small)
        }
    }

    private func enabled(_ row: Row, hasKeys: Bool) -> Binding<Bool> {
        Binding { hasKeys } set: { isOn in
            keyboard.edit(model: model) { config in
                if isOn {
                    config.reset(row.action, argument: row.argument, global: true, defaults: defaults)
                } else {
                    config.setKeys([], for: row.action, argument: row.argument, global: true, defaults: defaults)
                }
            }
        }
    }

    // MARK: Recording

    private func record(_ row: Row) {
        recorder.conflict = nil
        keyboard.setHotKeysSuspended(true)
        recorder.start(row) { strokes in
            keyboard.setHotKeysSuspended(false)
            guard let strokes else { return }
            // A global hotkey has to be one chord with a modifier.
            if row.global, strokes.count != 1 || strokes[0].modifiers.isDisjoint(with: [.command, .option, .control]) {
                NSSound.beep()
                return
            }
            let others = keyboard.keymap.conflicts(with: strokes, excluding: row.action, argument: row.argument, global: row.global)
            if others.isEmpty {
                set([strokes], for: row)
            } else {
                recorder.conflict = KeyRecorder.Conflict(row: row, strokes: strokes, others: others)
            }
        }
    }

    private func set(_ keys: [[KeyStroke]], for row: Row) {
        keyboard.edit(model: model) { $0.setKeys(keys, for: row.action, argument: row.argument, global: row.global, defaults: defaults) }
    }

    private func replace(_ conflict: KeyRecorder.Conflict) {
        let row = conflict.row
        keyboard.edit(model: model) { config in
            config.removeConflicts(with: conflict.strokes, keeping: row.action, argument: row.argument, global: row.global, defaults: defaults)
            config.setKeys([conflict.strokes], for: row.action, argument: row.argument, global: row.global, defaults: defaults)
        }
        recorder.conflict = nil
    }

    private func resetAll() {
        let alert = NSAlert()
        alert.messageText = "Reset every key to its default?"
        alert.informativeText = "This removes your bindings from keys.conf. Comments stay."
        alert.addButton(withTitle: "Reset All")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        keyboard.edit(model: model) { $0.resetAll() }
    }
}

/// A key field: shows the keys, or asks for new ones while recording.
private struct RecordButton: View {
    let bindings: [KeyBinding]
    let isRecording: Bool
    let start: () -> Void

    var body: some View {
        Button(action: start) {
            if isRecording || bindings.isEmpty {
                Text(isRecording ? "Press keys…" : "none")
                    .font(.callout)
                    .foregroundStyle(isRecording ? Color.accentColor : .secondary)
                    .lineLimit(1)
                    .frame(minWidth: 72)
            } else {
                HStack(spacing: 10) {
                    ForEach(bindings, id: \.self) { KeyChips(strokes: $0.strokes) }
                }
                .frame(minWidth: 72)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(isRecording ? "Press the new keys, or esc to cancel" : "Click, then press the new keys")
    }
}

/// Listens for the next keys pressed in the Settings window. A chord ends at once; a plain key
/// waits a moment for a second (for "g g").
@Observable
@MainActor
final class KeyRecorder {
    struct Conflict {
        let row: KeyboardSettings.Row
        let strokes: [KeyStroke]
        let others: [Keymap.Entry]
    }

    /// The row being recorded for.
    private(set) var target: KeyboardSettings.Row?
    var conflict: Conflict?
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var strokes: [KeyStroke] = []
    @ObservationIgnored private var finishTask: Task<Void, Never>?
    @ObservationIgnored private var completion: (([KeyStroke]?) -> Void)?

    func start(_ target: KeyboardSettings.Row, completion: @escaping ([KeyStroke]?) -> Void) {
        stop()
        self.target = target
        self.completion = completion
        strokes = []
        // Only keys pressed in Settings record; the desktop keeps its own.
        let windowNumber = NSApp.keyWindow?.windowNumber
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.windowNumber == windowNumber else { return event }
            MainActor.assumeIsolated {
                guard let self, let stroke = KeyStroke(event) else { return }
                self.take(stroke)
            }
            return nil
        }
    }

    private func take(_ stroke: KeyStroke) {
        finishTask?.cancel()
        if strokes.isEmpty, stroke == KeyStroke(key: "escape") {
            finish(nil)
            return
        }
        strokes.append(stroke)
        let isChord = !stroke.modifiers.isDisjoint(with: [.command, .option, .control])
        if strokes.count == 2 || (isChord && strokes.count == 1) {
            finish(strokes)
            return
        }
        // A plain key waits briefly for a second.
        finishTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, !Task.isCancelled else { return }
            self.finish(self.strokes)
        }
    }

    private func finish(_ strokes: [KeyStroke]?) {
        let completion = completion
        stop()
        completion?(strokes)
    }

    /// Ends recording with nothing recorded, so the caller can undo what it set up.
    func cancel() {
        finish(nil)
    }

    func stop() {
        finishTask?.cancel()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        target = nil
        completion = nil
    }
}

enum SettingsPath {
    static func abbreviated(_ url: URL) -> String {
        url.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}
