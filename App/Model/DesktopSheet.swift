import Foundation

/// What covers the desktop, if anything. Answering, terminals and clean-up add their own cases.
enum DesktopSheet: Hashable {
    case cleanup
    /// The ⌘K palette, opened with this text in its field (">" for commands).
    case palette(String)
    case git(GitAction, UUID)
    /// The palette in its Add project flow.
    case projects(ProjectFlow)
}

enum FocusDirection: Sendable {
    case left, right, up, down
}
