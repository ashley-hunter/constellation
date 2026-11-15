import Foundation

public struct Project: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var rootPath: URL
    public var swatch: ProjectSwatch
    public var setupScriptPath: URL?
    public var defaultProvider: Provider
    public var defaultBranch: String

    public init(
        id: UUID = UUID(),
        name: String,
        rootPath: URL,
        swatch: ProjectSwatch,
        setupScriptPath: URL? = nil,
        defaultProvider: Provider = .claudeCode,
        defaultBranch: String = "main"
    ) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.swatch = swatch
        self.setupScriptPath = setupScriptPath
        self.defaultProvider = defaultProvider
        self.defaultBranch = defaultBranch
    }

    /// The setup script used when none is configured, relative to the project root.
    public static let defaultSetupScript = ".constellation/setup.sh"
}

/// The canvas swatches, auto-assigned to projects in order.
public enum ProjectSwatch: String, CaseIterable, Codable, Sendable {
    case sage, lavender, rose, slate, teal, coral, gold, plum, moss, sky

    /// Ten hues far enough apart to tell projects apart at a glance on a dark surface.
    public var hex: String {
        switch self {
        case .sage: "#7CC4A0"
        case .lavender: "#A493F0"
        case .rose: "#EE8AAE"
        case .slate: "#8BA9C9"
        case .teal: "#4FC1C9"
        case .coral: "#F0906A"
        case .gold: "#D9C25E"
        case .plum: "#C27DD8"
        case .moss: "#A7C46A"
        case .sky: "#6FA8F0"
        }
    }

    /// The swatch for the next project: the first one no project uses yet, cycling once all are taken.
    public static func next(after used: [ProjectSwatch]) -> ProjectSwatch {
        allCases.first { !used.contains($0) } ?? allCases[used.count % allCases.count]
    }

    /// The projects with every repeated swatch after the first moved to an unused one, so no two share a
    /// colour while there are colours to spare. Projects keep their order and anything else about them.
    public static func unique(_ projects: [Project]) -> [Project] {
        var used: [ProjectSwatch] = []
        return projects.map { project in
            var project = project
            if used.contains(project.swatch), used.count < allCases.count {
                project.swatch = next(after: used)
            }
            used.append(project.swatch)
            return project
        }
    }
}

/// The machine a session runs on. Only this Mac in v1.
public enum Host: String, Hashable, Codable, Sendable {
    case thisMac
}

public enum Provider: String, CaseIterable, Hashable, Codable, Sendable {
    case claudeCode
    case codex

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }
}

public enum PermissionMode: String, CaseIterable, Hashable, Codable, Sendable {
    case askForEverything
    case askForRisky
    case fullAuto

    public static let `default` = PermissionMode.askForRisky
}
