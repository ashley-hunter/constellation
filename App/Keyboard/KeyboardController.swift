import AppKit
import ConstellationCore
import Observation

/// keys.conf and what the keyboard is doing: the resolved keymap, a sequence being typed, jump
/// hints, and whether a text field has the keys. The file is the only store: Settings
/// edits it, and hand edits are picked up when it is saved.
@Observable
@MainActor
final class KeyboardController {
    /// One tile's jump hint, while ⌘J hints are showing.
    struct Hint: Hashable {
        let item: TileItem
        let label: String
    }

    struct HintSession {
        var hints: [Hint]
        var typed = ""
        var opens = false
    }

    let url: URL
    private(set) var config: KeysConfig
    private(set) var keymap: Keymap
    /// Keys typed so far toward a sequence keys.conf binds, such as "g g".
    private(set) var pending: [KeyStroke] = []
    private(set) var showsDigitHints = false
    /// Holding ⌃ alone: each pile's label shows its project's number, for ⌃1-9.
    private(set) var showsProjectHints = false
    /// Holding ⌥ alone: the empty launcher's rows show their ⌥ keys.
    private(set) var showsOptionHints = false
    /// The first digit of a two-digit ⌘ label, typed while ⌘ is still held.
    var typedDigits = ""
    var hintSession: HintSession?
    /// A text field or terminal has the keys.
    var isEditingText = false

    @ObservationIgnored private var sequencer = KeySequencer()
    @ObservationIgnored private var pendingTask: Task<Void, Never>?
    @ObservationIgnored private var commandHoldTask: Task<Void, Never>?
    @ObservationIgnored private var controlHoldTask: Task<Void, Never>?
    @ObservationIgnored private var optionHoldTask: Task<Void, Never>?
    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private let hotKeys = GlobalHotKeys()
    @ObservationIgnored private var reportedProblems: [KeysConfig.Problem] = []

    static var defaults: KeymapDefaults { ActionRegistry.keymapDefaults }

    /// `~/.config/constellation/keys.conf`, or `-ConstellationKeysPath` for a scratch copy.
    static var defaultURL: URL {
        if let path = UserDefaults.standard.string(forKey: "ConstellationKeysPath") { return URL(filePath: path) }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/constellation/keys.conf")
    }

    init(url: URL = KeyboardController.defaultURL) {
        self.url = url
        let config = KeysConfig(parsing: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
        self.config = config
        keymap = Keymap(defaults: Self.defaults, config: config, knownActions: ActionRegistry.knownActionIDs)
    }

    // MARK: The file

    /// Writes the commented-out defaults on first launch, then watches the file and registers the
    /// global hotkeys.
    func start(model: AppModel) {
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            let titles = Dictionary(ActionRegistry.all.map { ($0.id.rawValue, $0.title) }) { first, _ in first }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try KeysConfig.template(defaults: Self.defaults, titles: titles).write(to: url, atomically: true, encoding: .utf8)
            } catch {
                Log.app.error("Writing keys.conf failed: \(error, privacy: .public)")
            }
        }
        hotKeys.onPress = { [weak model] rule in
            guard let model else { return }
            // Every hotkey brings Constellation forward, then acts there.
            NSApp.activate()
            // Onboarding's lessons and the launcher's ⌥ keys take the stroke before the global action.
            if model.onboarding != nil || model.launcherTakesKeys, rule.strokes.count == 1,
               model.handleKey(rule.strokes[0], isEditingText: false, inShell: false) { return }
            model.perform(ActionID(rawValue: rule.action), argument: rule.argument, via: .key)
        }
        watcher = DirectoryWatcher(directory) { [weak self, weak model] in
            guard let self, let model else { return }
            self.reload(model: model)
        }
        apply(config, model: model)
    }

    func reload(model: AppModel) {
        guard let text = try? String(contentsOf: url, encoding: .utf8), text != config.text else { return }
        apply(KeysConfig(parsing: text), model: model)
    }

    /// Edits keys.conf and writes it straight away.
    func edit(model: AppModel, _ change: (inout KeysConfig) -> Void) {
        var config = config
        change(&config)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try config.text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            model.notice = "Couldn't save keys.conf: \(error.localizedDescription)"
            return
        }
        apply(config, model: model)
    }

    private func apply(_ config: KeysConfig, model: AppModel) {
        self.config = config
        keymap = Keymap(defaults: Self.defaults, config: config, knownActions: ActionRegistry.knownActionIDs)
        hotKeys.register(keymap.globals)
        cancelSequence()
        let problems = keymap.problems
        if problems != reportedProblems, let first = problems.first {
            let more = problems.count > 1 ? " (and \(problems.count - 1) more)" : ""
            model.notice = "keys.conf \(first)\(more). The rest of the file still applies."
        }
        reportedProblems = problems
    }

    /// Settings turns the hotkeys off while it records keys, so it can record one of them.
    func setHotKeysSuspended(_ suspended: Bool) {
        hotKeys.register(suspended ? [] : keymap.globals)
    }

    // MARK: Sequences

    /// Feeds a key to the sequencer. A sequence waits a second for its next key, then runs what it
    /// already completes.
    func feed(_ stroke: KeyStroke, run: @escaping ([Keymap.Entry]) -> Bool) -> Bool {
        let outcome = sequencer.feed(stroke, in: keymap)
        pending = sequencer.pending
        pendingTask?.cancel()
        switch outcome {
        case .run(let entries):
            return run(entries)
        case .unmatched:
            return false
        case .wait:
            pendingTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                let entries = self.sequencer.timeOut(in: self.keymap)
                self.pending = []
                _ = run(entries)
            }
            return true
        }
    }

    var isSequencePending: Bool { !pending.isEmpty }

    func cancelSequence() {
        pendingTask?.cancel()
        sequencer.cancel()
        pending = []
    }

    // MARK: ⌘-hold badges

    /// Holding ⌘ alone for 250 ms shows the digit badges; letting go hides them.
    func commandChanged(isHeldAlone: Bool) {
        commandHoldTask?.cancel()
        guard isHeldAlone else {
            showsDigitHints = false
            typedDigits = ""
            return
        }
        commandHoldTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            self.showsDigitHints = true
        }
    }

    /// Holding ⌃ alone for 250 ms numbers the projects; letting go hides them.
    func controlChanged(isHeldAlone: Bool) {
        controlHoldTask?.cancel()
        guard isHeldAlone else {
            showsProjectHints = false
            return
        }
        controlHoldTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            self.showsProjectHints = true
        }
    }

    /// Holding ⌥ alone for 250 ms shows the launcher's ⌥ keys; letting go hides them.
    func optionChanged(isHeldAlone: Bool) {
        optionHoldTask?.cancel()
        guard isHeldAlone else {
            showsOptionHints = false
            return
        }
        optionHoldTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            self.showsOptionHints = true
        }
    }
}
