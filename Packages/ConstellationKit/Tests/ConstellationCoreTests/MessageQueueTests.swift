import Foundation
import Testing
@testable import ConstellationCore

@Suite struct MessageQueueTests {
    private func queued(_ text: String) -> QueuedMessage {
        QueuedMessage(sessionID: UUID(), message: UserMessage(text: text))
    }

    @Test func movesClampToTheEnds() {
        var queue = ["a", "b", "c"].map(queued)
        queue.move(queue[2].id, by: -1)
        #expect(queue.map(\.message.text) == ["a", "c", "b"])
        queue.move(queue[0].id, by: 5)
        #expect(queue.map(\.message.text) == ["c", "b", "a"])
        queue.move(queue[0].id, by: -1)
        #expect(queue.map(\.message.text) == ["c", "b", "a"])
    }

    @Test func removeReturnsTheMessage() {
        var queue = ["a", "b"].map(queued)
        let first = queue[0].id
        #expect(queue.remove(first)?.message.text == "a")
        #expect(queue.remove(first) == nil)
        #expect(queue.map(\.message.text) == ["b"])
    }

    @Test func sendingQueuesWhileWorkingUnlessSteering() {
        #expect(makeSession(runState: .working).sendRoute(steer: false) == .queue)
        #expect(makeSession(runState: .working).sendRoute(steer: true) == .steer)
        #expect(makeSession(runState: .preparing(.setup)).sendRoute(steer: true) == .queue)
        for state: RunState in [.done, .interrupted, .failed(.turnError)] {
            #expect(makeSession(runState: state).sendRoute(steer: false) == .startTurn)
        }
    }

    @Test func aPendingAskTakesTheReply() {
        var session = makeSession(runState: .working)
        session = session.reducing(.askRaised(Ask(id: "1", sessionID: session.id, kind: .permission(PermissionAsk(toolName: "Bash", summary: "ls")))))
        #expect(session.sendRoute(steer: true) == .answerAsk)
    }

    @Test func onlyAFinishedTurnFlushes() {
        #expect(MessageQueue.shouldFlush(from: .working, to: .done))
        #expect(MessageQueue.shouldFlush(from: .blocked, to: .done))
        #expect(!MessageQueue.shouldFlush(from: .done, to: .done))
        #expect(!MessageQueue.shouldFlush(from: .working, to: .interrupted))
        #expect(!MessageQueue.shouldFlush(from: .working, to: .failed(.turnError)))
    }
}
