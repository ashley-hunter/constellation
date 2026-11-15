import Darwin
import Foundation
import Synchronization

/// Pid files for running children, so ones left behind by a crash or SIGTERM can be stopped: by
/// the watchdog the moment the app dies, and by a sweep at the next launch.
///
/// Each file is `<pid>.pid` holding the pid and the process's start time, so a pid the system has
/// since reused is never signalled. Every child leads its own process group, so stopping one
/// stops what it started too. Nothing is written until ``track(in:)`` names a directory.
///
/// Each run of the app keeps its files in its own folder, `<app pid>-<start time>`, so a second
/// copy of the app running at once never stops the first one's children.
public enum ChildRegistry {
    public struct Leftover: Hashable, Sendable {
        public var pid: pid_t
        public var startTime: UInt64
        public var name: String
    }

    private static let directory = Mutex<URL?>(nil)

    public static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Constellation/children", directoryHint: .isDirectory)
    }

    /// Starts writing pid files for new children into `directory`.
    public static func track(in directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory.withLock { $0 = directory }
    }

    public static func stopTracking() {
        directory.withLock { $0 = nil }
    }

    static func register(_ pid: pid_t, name: String) {
        guard let directory = directory.withLock({ $0 }) else { return }
        writeFile(for: pid, name: name, in: directory)
    }

    static func writeFile(for pid: pid_t, name: String, in directory: URL) {
        guard let start = startTime(of: pid) else { return }
        let contents = "\(pid) \(start)\n\(name)\n"
        try? Data(contents.utf8).write(to: file(for: pid, in: directory), options: .atomic)
    }

    static func unregister(_ pid: pid_t) {
        guard let directory = directory.withLock({ $0 }) else { return }
        try? FileManager.default.removeItem(at: file(for: pid, in: directory))
    }

    /// This run's folder under `base`.
    public static func runDirectory(in base: URL) -> URL {
        let pid = getpid()
        return base.appending(path: "\(pid)-\(startTime(of: pid) ?? 0)", directoryHint: .isDirectory)
    }

    /// Collects the leftovers of every run under `base` whose app has gone, removing their
    /// folders. Folders of runs still going are left alone.
    public static func collectLeftovers(ofEndedRunsIn base: URL) -> [Leftover] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        // Pid files from before runs had folders.
        var leftovers = collectLeftovers(in: base)
        for folder in entries where (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            if let owner = parseRun(folder.lastPathComponent), isAlive(owner) { continue }
            leftovers += collectLeftovers(in: folder)
            try? FileManager.default.removeItem(at: folder)
        }
        return leftovers
    }

    static func parseRun(_ name: String) -> Leftover? {
        let fields = name.split(separator: "-")
        guard fields.count == 2, let pid = pid_t(fields[0]), pid > 1, let start = UInt64(fields[1]) else { return nil }
        return Leftover(pid: pid, startTime: start, name: "Constellation")
    }

    /// Reads and removes every pid file in `directory`, returning the children still running.
    /// Call it before ``track(in:)`` so the files of new children are never collected.
    public static func collectLeftovers(in directory: URL) -> [Leftover] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "pid" }.compactMap { file in
            defer { try? FileManager.default.removeItem(at: file) }
            guard let leftover = parse(String(decoding: (try? Data(contentsOf: file)) ?? Data(), as: UTF8.self)) else { return nil }
            return isAlive(leftover) ? leftover : nil
        }
    }

    /// SIGTERM to each leftover's process group, then SIGKILL to any still there after `grace`.
    public static func stop(_ leftovers: [Leftover], grace: Duration = .seconds(2)) async {
        guard !leftovers.isEmpty else { return }
        for leftover in leftovers { kill(-leftover.pid, SIGTERM) }
        let deadline = ContinuousClock.now + grace
        var remaining = leftovers
        while !remaining.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
            remaining = remaining.filter(isAlive)
        }
        for leftover in remaining { kill(-leftover.pid, SIGKILL) }
    }

    static func parse(_ contents: String) -> Leftover? {
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
        let fields = lines.first?.split(separator: " ") ?? []
        guard fields.count == 2, let pid = pid_t(fields[0]), pid > 1, let start = UInt64(fields[1]) else { return nil }
        return Leftover(pid: pid, startTime: start, name: lines.count > 1 ? String(lines[1]) : "")
    }

    /// Still running and still the process the file was written for.
    static func isAlive(_ leftover: Leftover) -> Bool {
        startTime(of: leftover.pid) == leftover.startTime
    }

    /// Microseconds since the epoch at which `pid` started, or nil if there is no such process.
    static func startTime(of pid: pid_t) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        // A zombie has exited already; its group may still need stopping, but its pid can't be trusted.
        guard info.pbi_status != UInt32(SZOMB) else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }

    private static func file(for pid: pid_t, in directory: URL) -> URL {
        directory.appending(path: "\(pid).pid")
    }
}

extension ChildRegistry {
    /// The watchdog: a separate process whose stdin is a pipe only the app holds open. However the
    /// app ends, even by SIGKILL or a crash, the kernel closes that pipe, and the watchdog stops
    /// every child the app left in `directory`, its run's own folder, then removes the folder.
    public static func runWatchdog(directory: URL) async {
        var byte: UInt8 = 0
        while true {
            let count = read(STDIN_FILENO, &byte, 1)
            if count == 0 || (count < 0 && errno != EINTR) { break }
        }
        await stop(collectLeftovers(in: directory))
        try? FileManager.default.removeItem(at: directory)
    }

    /// Starts the watchdog `helper` runs with `arguments`, untracked so it never stops itself.
    /// Keep the returned process for as long as the app runs: releasing it closes the pipe.
    public static func startWatchdog(helper: URL, arguments: [String]) throws -> ChildProcess {
        try ChildProcess(
            executable: helper,
            arguments: arguments,
            environment: ProcessInfo.processInfo.environment,
            standardInput: .pipe,
            standardOutput: .null,
            standardError: .null,
            tracked: false
        )
    }
}
