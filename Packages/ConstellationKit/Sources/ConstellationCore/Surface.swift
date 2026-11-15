import Foundation

/// What has the screen and the keys: the one thing on top. esc, which keys reach the desktop, where
/// typing goes and what an action acts on all read this, so they agree. Highest first:
///
/// 1. `onboarding`: the first-run flow, over everything.
/// 2. `attachment`: an image zoomed over whatever it came from.
/// 3. `sheet`: the palette, Git, clean-up or Add project.
/// 4. `terminal`: an opened terminal, browser or note, over a session or the grid as well.
/// 5. `grid`: the split screen, `focused` being the opened session; `isPicking` while its next
///    slot shows the sessions to fill it with.
/// 6. `session`: the opened session or draft on its own.
/// 7. `launcher`: the "Start a session" card, while its draft isn't open.
/// 8. `inlineComposer`: a full tile's reply box on the desktop.
/// 9. `desktop`: the piles.
public enum Surface<Sheet: Hashable>: Hashable {
    case onboarding
    case attachment
    case sheet(Sheet)
    case terminal(UUID)
    case grid(focused: UUID?, isPicking: Bool, isZoomed: Bool)
    case session(UUID)
    case launcher
    case inlineComposer(UUID)
    case desktop

    /// The highest of whatever is showing. `grid` is set while the split screen or its picker shows.
    public init(
        onboarding: Bool = false,
        attachment: Bool = false,
        sheet: Sheet? = nil,
        terminal: UUID? = nil,
        grid: (isPicking: Bool, isZoomed: Bool)? = nil,
        session: UUID? = nil,
        launcher: Bool = false,
        inlineComposer: UUID? = nil
    ) {
        if onboarding {
            self = .onboarding
        } else if attachment {
            self = .attachment
        } else if let sheet {
            self = .sheet(sheet)
        } else if let terminal {
            self = .terminal(terminal)
        } else if let grid {
            self = .grid(focused: session, isPicking: grid.isPicking, isZoomed: grid.isZoomed)
        } else if let session {
            self = .session(session)
        } else if launcher {
            self = .launcher
        } else if let inlineComposer {
            self = .inlineComposer(inlineComposer)
        } else {
            self = .desktop
        }
    }

    /// A panel or sheet is over the piles, so they take no keys or focus. Onboarding and the
    /// launcher leave the desktop's own state alone.
    public var coversDesktop: Bool {
        switch self {
        case .attachment, .sheet, .terminal, .grid, .session: true
        case .onboarding, .launcher, .inlineComposer, .desktop: false
        }
    }

    /// The session whose view has the keys: the opened one, alone or focused in the grid.
    public var sessionID: UUID? {
        switch self {
        case .session(let id): id
        case .grid(let focused, _, _): focused
        default: nil
        }
    }
}
