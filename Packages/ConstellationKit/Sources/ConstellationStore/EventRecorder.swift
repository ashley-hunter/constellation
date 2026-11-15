import ConstellationCore
import Foundation
import os

/// Numbers session events as they arrive and writes them to the store in one transaction per interval.
public actor EventRecorder {
    private let store: Store
    private let interval: Duration
    private var pending: [StoredEvent] = []
    private var lastSequences: [UUID: Int] = [:]
    private var scheduledFlush: Task<Void, Never>?
    private let logger = Logger(subsystem: "dev.ashleyhunter.constellation", category: "store")

    public init(store: Store, interval: Duration = .milliseconds(250)) {
        self.store = store
        self.interval = interval
    }

    /// Queues an event and returns its sequence number within the session.
    @discardableResult
    public func record(_ event: SessionEvent, for sessionID: UUID, at time: Date = .now) -> Int {
        let sequence = nextSequence(for: sessionID)
        pending.append(StoredEvent(sessionID: sessionID, sequence: sequence, time: time, event: event))
        scheduleFlush()
        return sequence
    }

    /// Writes everything queued now. Call before quitting. On failure the events stay queued.
    public func flush() throws {
        scheduledFlush?.cancel()
        scheduledFlush = nil
        guard !pending.isEmpty else { return }
        let batch = pending
        try store.append(batch)
        pending.removeFirst(batch.count)
    }

    private func flushOnSchedule() {
        scheduledFlush = nil
        do {
            try flush()
        } catch {
            logger.error("Writing \(self.pending.count) events failed: \(error.localizedDescription)")
        }
        if !pending.isEmpty { scheduleFlush() }
    }

    private func scheduleFlush() {
        guard scheduledFlush == nil else { return }
        scheduledFlush = Task { [interval] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            self.flushOnSchedule()
        }
    }

    private func nextSequence(for sessionID: UUID) -> Int {
        let last = lastSequences[sessionID] ?? storedLastSequence(for: sessionID)
        lastSequences[sessionID] = last + 1
        return last + 1
    }

    private func storedLastSequence(for sessionID: UUID) -> Int {
        do {
            return try store.lastSequence(for: sessionID) ?? 0
        } catch {
            logger.error("Reading the last event sequence failed: \(error.localizedDescription)")
            return 0
        }
    }
}
