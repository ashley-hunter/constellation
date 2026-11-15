import Foundation

/// A command a project offers to run as a task: its package.json scripts, through the package
/// manager its lockfile names, and its Makefile's targets.
public struct ProjectTask: Hashable, Sendable {
    public var name: String
    public var command: String

    public init(name: String, command: String) {
        self.name = name
        self.command = command
    }

    // ponytail: package.json and Makefile only; add justfile, Cargo or Procfile when a project needs them.
    public static func suggestions(in root: URL) -> [ProjectTask] {
        let manager = packageManager(in: root)
        var tasks: [ProjectTask] = []
        if let data = try? Data(contentsOf: root.appending(path: "package.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let scripts = json["scripts"] as? [String: Any] {
            tasks += scripts.keys.sorted().map { ProjectTask(name: $0, command: manager == "npm" ? "npm run \($0)" : "\(manager) \($0)") }
        }
        if let makefile = try? String(contentsOf: root.appending(path: "Makefile"), encoding: .utf8) {
            tasks += makeTargets(in: makefile).map { ProjectTask(name: $0, command: "make \($0)") }
        }
        return tasks
    }

    static func packageManager(in root: URL) -> String {
        let lockfiles = [("pnpm-lock.yaml", "pnpm"), ("yarn.lock", "yarn"), ("bun.lockb", "bun"), ("bun.lock", "bun")]
        let manager = lockfiles.first { FileManager.default.fileExists(atPath: root.appending(path: $0.0).path(percentEncoded: false)) }
        return manager?.1 ?? "npm"
    }

    /// Rules at the start of a line, leaving out special targets (.PHONY), patterns and variables.
    static func makeTargets(in makefile: String) -> [String] {
        var seen = Set<String>()
        return makefile.split(separator: "\n").compactMap { line in
            guard let match = line.wholeMatch(of: /([A-Za-z0-9][\w.-]*)\s*:(?!=).*/) else { return nil }
            let name = String(match.output.1)
            return seen.insert(name).inserted ? name : nil
        }
    }
}
