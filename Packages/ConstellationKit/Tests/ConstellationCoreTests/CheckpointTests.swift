import Foundation
import Testing
@testable import ConstellationCore

@Suite struct CheckpointTests {
    /// Three Claude Code turns; the third message was sent after a resume, when the CLI didn't
    /// know the head, so it comes from the second turn's end.
    let claude: [SessionEvent] = [
        .userMessage("one"), .checkpoint(Checkpoint(turnID: "u1", resumeAt: nil, commit: "c1")),
        .assistantText("ok", isFinal: true), .conversationHead("a1"),
        .userMessage("two"), .checkpoint(Checkpoint(turnID: "u2", resumeAt: "a1", commit: "c2")),
        .assistantText("ok again", isFinal: true), .conversationHead("a2"),
        .userMessage("three"), .checkpoint(Checkpoint(turnID: "u3")),
        .assistantText("done", isFinal: true), .conversationHead("a3"),
    ]

    @Test func checkpointsBelongToTheMessageBeforeThem() {
        let transcript = Transcript(claude)
        #expect(transcript.messageEntryIDs == [0, 2, 4])
        #expect(transcript.checkpoint(forMessage: 1)?.commit == "c2")
        #expect(transcript.checkpoint(forMessage: 2)?.resumeAt == "a2")
        #expect(transcript.messageIndex(ofEntry: 4) == 2)
        #expect(transcript.messageIndex(ofEntry: 3) == nil)
    }

    @Test func claudeRewindsResumeAtTheMessageBefore() {
        let transcript = Transcript(claude)
        #expect(transcript.rewindCut(toMessage: 0, provider: .claudeCode) == .rewind(before: nil))
        #expect(transcript.rewindCut(toMessage: 2, provider: .claudeCode) == .rewind(before: "a2"))
    }

    @Test func claudeForksResumeAtTheEndOfTheMessagesTurn() {
        let transcript = Transcript(claude)
        #expect(transcript.forkCut(atMessage: 0, provider: .claudeCode) == .fork(through: "a1"))
        #expect(transcript.forkCut(atMessage: 2, provider: .claudeCode) == .fork(through: "a3"))
    }

    @Test func codexCutsAtTurnsAndSkipsSteers() {
        let transcript = Transcript([
            .userMessage("one"), .checkpoint(Checkpoint(turnID: "t1")),
            .userMessage("steer"),
            .userMessage("two"), .checkpoint(Checkpoint(turnID: "t2")),
        ])
        #expect(transcript.rewindCut(toMessage: 0, provider: .codex) == .rewind(before: "t1"))
        #expect(transcript.forkCut(atMessage: 2, provider: .codex) == .fork(through: "t2"))
        #expect(transcript.rewindCut(toMessage: 1, provider: .codex) == nil)
        #expect(transcript.forkCut(atMessage: 1, provider: .codex) == nil)
    }

    @Test func rewoundDropsTheMessageAndEverythingAfter() {
        var transcript = Transcript(claude)
        #expect(transcript.messagesLost(rewindingTo: 1) == 2)
        transcript.append(.rewound(toMessage: 1))
        #expect(transcript.entries.map(\.id) == [0, 1])
        #expect(transcript.messageEntryIDs == [0])
        #expect(transcript.head == "a1")
        #expect(transcript.checkpoint(forMessage: 1) == nil)

        // The next message picks up from the rewind point.
        transcript.append(.userMessage("two, again"))
        transcript.append(.checkpoint(Checkpoint(turnID: "u4")))
        #expect(transcript.checkpoint(forMessage: 1)?.resumeAt == "a1")
        #expect(transcript.entries.last == .user(id: 2, text: "two, again"))
    }

    @Test func forkHistoryStopsBeforeTheNextMessage() {
        let events: [SessionEvent] = [.started(nativeID: "n"), .runState(.working)] + claude
        let history = Transcript.history(events, throughMessage: 1)
        #expect(history.first == .userMessage("one"))
        #expect(history.last == .conversationHead("a2"))
        #expect(!history.contains(.userMessage("three")))
        #expect(!history.contains(.started(nativeID: "n")))

        // After a rewind, message 1 is the one sent after it.
        let rewound = claude + [.rewound(toMessage: 1), .userMessage("two b"), .checkpoint(Checkpoint(turnID: "u5")), .userMessage("three b")]
        #expect(Transcript(Transcript.history(rewound, throughMessage: 1)).entries.last == .user(id: 2, text: "two b"))
    }

    @Test func newEventsStillDecodeAndRoundTrip() throws {
        for event: SessionEvent in [.checkpoint(Checkpoint(turnID: "t", resumeAt: "r", commit: "c")), .conversationHead("h"), .rewound(toMessage: 3)] {
            #expect(try JSONDecoder().decode(SessionEvent.self, from: JSONEncoder().encode(event)) == event)
        }
    }
}
