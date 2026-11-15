import ConstellationCore
import Foundation

/// Tokens, cost and context per session, from the providers' usage reports.
extension AppModel {
    func recordUsage(_ report: TokenUsage, for id: UUID, at time: Date) {
        guard let provider = sessionsByID[id]?.provider else { return }
        usage[id, default: SessionUsage()].add(report)
        let store = services.store
        Task.detached {
            do { try store.addUsage(report, sessionID: id, provider: provider, at: time) } catch {
                Log.app.error("Saving usage failed: \(error, privacy: .public)")
            }
        }
    }

    func restoreUsage() {
        let store = services.store
        Task { [weak self] in
            let stored = await Task.detached { (try? store.sessionUsage()) ?? [:] }.value
            // Reports that arrived while loading are already counted in the store's totals.
            self?.usage = stored.merging(self?.usage ?? [:]) { stored, _ in stored }
        }
    }
}
