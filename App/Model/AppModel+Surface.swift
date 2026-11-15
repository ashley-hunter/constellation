import ConstellationCore
import Foundation

/// What is in front, and bringing something there. The stored state stays as it is (`sheet`,
/// `openedSessionID`, `grid` and the rest); `surface` reads it in one order, and every opener
/// clears what would cover it through `clearFront(keeping:)`.
extension AppModel {
    /// What has the screen and the keys (see `Surface` for the order). esc, the keys that reach the
    /// desktop and where typing goes all follow it.
    var surface: Surface<DesktopSheet> {
        Surface(
            onboarding: onboarding != nil,
            attachment: zoomedAttachment != nil,
            sheet: sheet,
            terminal: openedTerminalID.flatMap { terminalsByID[$0] != nil ? $0 : nil },
            grid: grid != nil || gridPicking != nil ? (gridPicking != nil, grid?.isZoomed == true) : nil,
            session: openedSessionID.flatMap { sessionsByID[$0] != nil ? $0 : nil },
            launcher: showsLauncher && !launcherIsCovered,
            inlineComposer: inlineComposerID
        )
    }

    /// What an opener leaves in place when it clears the front.
    struct FrontKeeps: OptionSet {
        let rawValue: Int
        /// A terminal opened over the session view stays over it.
        static let terminal = FrontKeeps(rawValue: 1 << 0)
        /// The grid's picker keeps its slot and the keys.
        static let gridPicking = FrontKeeps(rawValue: 1 << 1)
        /// The palette stays open, as it does when you only look at a row.
        static let sheet = FrontKeeps(rawValue: 1 << 2)
    }

    /// Clears whatever would sit over what is coming to the front, or take its keys: the jump hints
    /// and a ⌘-spread pile, a sheet, a zoomed image, a tile's inline composer, the opened terminal
    /// and the grid's picker. Every opener calls this first, so they all clear the same set;
    /// `kept` names what that opener means to leave.
    func clearFront(keeping kept: FrontKeeps = []) {
        endHints()
        if !kept.contains(.sheet), sheet != nil { sheet = nil }
        if zoomedAttachment != nil { zoomedAttachment = nil }
        if inlineComposerID != nil { inlineComposerID = nil }
        if !kept.contains(.terminal), openedTerminalID != nil { openedTerminalID = nil }
        if !kept.contains(.gridPicking), gridPicking != nil { gridPicking = nil }
    }
}
