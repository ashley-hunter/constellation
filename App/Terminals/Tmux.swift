import Foundation

/// Keeps terminals' shells running in tmux, on a server of Constellation's own, so they outlive a
/// quit, crash or update and reattach at launch. Each terminal is a tmux session named by its id.
/// Without tmux installed, shells run straight on the app's pty and end with it, as before.
enum Tmux {
    /// The real app's server. A development run on its own store (`-ConstellationStorePath`) gets
    /// one of its own, so it never reattaches to or stops the real app's shells.
    static let socket: String = {
        guard let path = UserDefaults.standard.string(forKey: "ConstellationStorePath") else { return "constellation" }
        let hash = path.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        return "constellation-\(String(hash, radix: 36))"
    }()

    static let executable: URL? = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        .map { URL(filePath: $0) }
        .first { FileManager.default.isExecutableFile(atPath: $0.path(percentEncoded: false)) }

    /// tmux is installed and the shell integration that reads each shell's environment is in place.
    static var isAvailable: Bool {
        executable != nil && configuration != nil && ShellIntegration.zshDirectory != nil
    }

    /// What starts or reattaches one terminal's session.
    struct Launch: Sendable {
        let name: String
        /// Its session is still running from an earlier launch.
        let attaches: Bool
        /// What it printed before this launch, beyond the screen tmux redraws on attach.
        var history = Data()
    }

    static func name(for id: UUID) -> String {
        id.uuidString.lowercased()
    }

    /// Out of the way: no prefix key, bindings or status line, so every key reaches the shell. No
    /// alternate screen, so output scrolls into the terminal's own scrollback. Passthrough lets the
    /// shell's OSC 133 marks reach the app.
    static let configuration: URL? = {
        let file = URL.applicationSupportDirectory.appending(path: "Constellation/tmux.conf")
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try configurationText.write(to: file, atomically: true, encoding: .utf8)
            return file
        } catch {
            Log.app.error("tmux configuration not written: \(error, privacy: .public)")
            return nil
        }
    }()

    static let configurationText = """
    # Written by Constellation for the tmux server that keeps its terminals running.
    set -g prefix None
    set -g prefix2 None
    unbind -a -T prefix
    unbind -a -T root
    set -g status off
    set -g mouse off
    set -g escape-time 0
    set -g history-limit 50000
    set -g default-terminal tmux-256color
    set -g allow-passthrough on
    set -g allow-rename off
    set -g focus-events on
    set -g destroy-unattached off
    set -g exit-empty on
    set -ga terminal-overrides ',xterm-256color:smcup@:rmcup@'
    set -as terminal-features ',xterm-256color:RGB'

    """

    /// The full command line for a tmux client on Constellation's server.
    static func arguments(_ command: [String]) -> [String] {
        ["-L", socket, "-f", configuration?.path(percentEncoded: false) ?? "/dev/null"] + command
    }

    /// Runs a tmux command to completion, returning its output, or nil if it failed.
    @discardableResult
    static func run(_ command: [String]) -> Data? {
        guard let executable else { return nil }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments(command)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }

    /// The sessions running on Constellation's server, by name, with the worktree port each was
    /// given. Empty when the server isn't running.
    static func sessions() -> [String: Int?] {
        guard let data = run(["list-sessions", "-F", "#{session_name}"]) else { return [:] }
        let names = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        return Dictionary(uniqueKeysWithValues: names.map { name in
            let line = run(["show-environment", "-t", name, "CONSTELLATION_PORT"]).map { String(decoding: $0, as: UTF8.self) }
            return (name, line?.split(separator: "=").last.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
        })
    }

    /// How to start the terminal's shell: reattaching its session if it's still running, with what
    /// it printed earlier to fill the scrollback.
    static func launch(for id: UUID) -> Launch? {
        guard isAvailable else { return nil }
        let name = name(for: id)
        guard run(["has-session", "-t", "=\(name)"]) != nil else { return Launch(name: name, attaches: false) }
        let history = run(["capture-pane", "-p", "-e", "-J", "-S", "-50000", "-E", "-1", "-t", "=\(name):"]) ?? Data()
        return Launch(name: name, attaches: true, history: history)
    }

    static func kill(_ id: UUID) {
        run(["kill-session", "-t", "=\(name(for: id))"])
    }

    /// Writes the shell's environment where its `.zshenv` reads it once and deletes it, so secrets
    /// never sit in tmux's own environment or on a command line.
    static func writeEnvironment(_ environment: [String: String], for name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "constellation-shells", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appending(path: "\(name).env")
        let skipped: Set<String> = ["TERM", "TERM_PROGRAM", "ZDOTDIR", "TMUX", "TMUX_PANE"]
        let lines = environment
            .filter { !skipped.contains($0.key) && $0.key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } }
            .sorted { $0.key < $1.key }
            .map { "export \($0.key)='\($0.value.replacingOccurrences(of: "'", with: "'\\''"))'" }
        FileManager.default.createFile(atPath: file.path(percentEncoded: false), contents: nil, attributes: [.posixPermissions: 0o600])
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: false, encoding: .utf8)
        return file
    }
}
