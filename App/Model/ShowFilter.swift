import ConstellationCore

/// The sidebar's Show filter.
enum ShowFilter: String, CaseIterable, Identifiable, Sendable {
    case all, needsYou, failed, working, doneNotSeen

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "Everything"
        case .needsYou: "Needs you"
        case .failed: "Failed"
        case .working: "Working"
        case .doneNotSeen: "Done, not seen"
        }
    }

    /// The SF Symbol the sidebar shows: chat bubbles, matching the chat icons on tiles.
    var symbol: String {
        switch self {
        case .all: "circle.grid.2x2"
        case .needsYou: "questionmark.bubble"
        case .failed: "exclamationmark.bubble"
        case .working: "ellipsis.bubble"
        case .doneNotSeen: "checkmark.bubble"
        }
    }


    func matches(_ session: Session) -> Bool {
        switch self {
        case .all: true
        case .needsYou: session.runState == .blocked || session.pullRequestNeedsYou
        case .failed: if case .failed = session.runState { true } else { false }
        case .working:
            switch session.runState {
            case .preparing, .working: true
            default: false
            }
        case .doneNotSeen: session.runState == .done && session.lifecycle == .unseen
        }
    }
}
