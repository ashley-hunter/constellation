import ConstellationCore
import Foundation

/// How a terminal's shell starts: a login zsh (argv0 `-zsh`) in its folder, with the app's
/// environment, the secrets it may see, its worktree's port, and a zsh integration that reports
/// OSC 133 marks. In tmux when it's installed (see ``Tmux``), so the shell outlives the app.
struct ShellLaunch {
    static let executable = "/bin/zsh"
    static let argv0 = "-zsh"

    let directory: URL
    let secrets: [String: String]
    /// The worktree's port, nil in the project's main checkout.
    var port: Int?
    /// Its tmux session, when it has one.
    var tmux: Tmux.Launch?

    /// What runs on the pty.
    struct Spawn {
        let executable: URL
        let arguments: [String]
        let argv0: String?
        let environment: [String: String]
    }

    /// The shell itself, or a tmux client that starts its session or reattaches it.
    func spawn() throws -> Spawn {
        guard let tmux, let executable = Tmux.executable else {
            return Spawn(executable: URL(filePath: Self.executable), arguments: [], argv0: Self.argv0, environment: environment())
        }
        // The client's environment is the server's if it starts it, so it carries no secrets or port.
        var client = ShellLaunch(directory: directory, secrets: [:]).environment()
        for key in ["TMUX", "TMUX_PANE"] { client[key] = nil }
        guard !tmux.attaches else {
            return Spawn(executable: executable, arguments: Tmux.arguments(["attach-session", "-t", "=\(tmux.name)"]), argv0: nil, environment: client)
        }
        let file = try Tmux.writeEnvironment(environment(), for: tmux.name)
        var arguments = ["new-session", "-s", tmux.name, "-c", directory.path(percentEncoded: false), "-e", "CONSTELLATION_ENV_FILE=\(file.path(percentEncoded: false))"]
        if let zdotdir = client["ZDOTDIR"] { arguments += ["-e", "ZDOTDIR=\(zdotdir)"] }
        if let port { arguments += ["-e", "CONSTELLATION_PORT=\(port)"] }
        arguments += [Self.executable, "-l"]
        return Spawn(executable: executable, arguments: Tmux.arguments(arguments), argv0: nil, environment: client)
    }

    func environment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = base
        // Ghostty sets GHOSTTY_RESOURCES_DIR on the app for its own use; a zshrc that sees it would
        // source Ghostty's shell integration over ours.
        for key in ["__CFBundleIdentifier", "XPC_SERVICE_NAME", "XPC_FLAGS", "PWD", "OLDPWD", "GHOSTTY_RESOURCES_DIR"] { environment[key] = nil }
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "Constellation"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        if let integration = ShellIntegration.zshDirectory {
            environment["CONSTELLATION_ZDOTDIR"] = base["ZDOTDIR"]
            environment["ZDOTDIR"] = integration.path(percentEncoded: false)
        }
        if let port { environment.merge(WorktreePort.environment(port)) { $1 } }
        environment.merge(secrets) { _, secret in secret }
        return environment
    }
}

/// A `.zshenv` that puts your own ZDOTDIR back, sources your `.zshenv`, and adds precmd and preexec
/// hooks printing OSC 133 marks, so the tile can show running or idle and the last exit code. The
/// rest of your startup files load as usual from your own ZDOTDIR. In tmux it first reads the
/// environment Constellation left for it, and wraps the marks for tmux to pass through.
enum ShellIntegration {
    static let zshDirectory: URL? = {
        let directory = URL.applicationSupportDirectory.appending(path: "Constellation/shell-integration/zsh", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try zshenv.write(to: directory.appending(path: ".zshenv"), atomically: true, encoding: .utf8)
            return directory
        } catch {
            Log.app.error("Shell integration not installed: \(error, privacy: .public)")
            return nil
        }
    }()

    static let zshenv = #"""
    # Written by Constellation for its terminals. Restores your ZDOTDIR, then reports OSC 133 marks.
    if [[ -n "${CONSTELLATION_ENV_FILE-}" ]]; then
      [[ -r "$CONSTELLATION_ENV_FILE" ]] && builtin source "$CONSTELLATION_ENV_FILE"
      /bin/rm -f -- "$CONSTELLATION_ENV_FILE"
      unset CONSTELLATION_ENV_FILE
    fi
    if [[ -n "${CONSTELLATION_ZDOTDIR-}" ]]; then
      ZDOTDIR="$CONSTELLATION_ZDOTDIR"
    else
      unset ZDOTDIR
    fi
    unset CONSTELLATION_ZDOTDIR
    [[ -r "${ZDOTDIR:-$HOME}/.zshenv" ]] && builtin source "${ZDOTDIR:-$HOME}/.zshenv"

    if [[ -o interactive ]]; then
      _constellation_mark() {
        if [[ -n "${TMUX-}" ]]; then
          builtin print -nr -- $'\ePtmux;\e\e]133;'"$1"$'\a\e\\'
        else
          builtin print -nr -- $'\e]133;'"$1"$'\a'
        fi
      }
      _constellation_preexec() {
        _constellation_ran=1
        _constellation_mark C
      }
      _constellation_precmd() {
        local code=$?
        if [[ -n "${_constellation_ran-}" ]]; then
          _constellation_mark "D;$code"
          unset _constellation_ran
        fi
        # redraw=0: Ghostty otherwise clears the prompt on resize for zsh to redraw, and it doesn't.
        _constellation_mark "A;redraw=0"
      }
      autoload -Uz add-zsh-hook
      add-zsh-hook preexec _constellation_preexec
      add-zsh-hook precmd _constellation_precmd
    fi

    """#
}
