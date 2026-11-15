import AppKit
import ConstellationCore
import Observation
@preconcurrency import UserNotifications

/// Watches the model for sessions that become blocked or fail. It keeps the Dock badge at the
/// blocked count and posts a notification for each. A notification for an ask can answer it from
/// the banner: a permission with Allow once, Deny and Always in project when offered, a single
/// question with up to three options by name, and either with Reply. Clicking it focuses the tile.
@MainActor
final class AttentionCenter: NSObject {
    private enum Signal: Equatable {
        case blocked(askID: String?)
        case failed
        case other
    }

    private enum Action {
        static let reply = "reply"
        static let permissionCategory = "permission"
        static let questionCategory = "question"

        /// A permission decision's action is named for the decision.
        static func decision(_ decision: PermissionDecision) -> String { decision.rawValue }
        static func option(_ index: Int) -> String { "option.\(index)" }
    }

    private let model: AppModel
    private let center = UNUserNotificationCenter.current()
    private var signals: [UUID: Signal] = [:]
    /// Every category registered, by identifier. A question's options name its actions, so each
    /// session with a question notification has its own, dropped when the notification goes.
    private var categories: [String: UNNotificationCategory] = [:]

    init(model: AppModel) {
        self.model = model
    }

    func start() {
        center.delegate = self
        for offered: [PermissionDecision] in [[.allowOnce, .deny], [.allowOnce, .deny, .allowAlwaysInProject]] {
            let category = Self.permissionCategory(offered)
            categories[category.identifier] = category
        }
        center.setNotificationCategories(Set(categories.values))
        // Onboarding asks on its Permissions step, with a sample of what you'd get.
        let isOnboarding = model.onboarding != nil
        Task {
            guard !isOnboarding else { return }
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                if !granted { Log.app.notice("Notifications are turned off for Constellation") }
            } catch {
                Log.app.error("Notification authorization failed: \(error, privacy: .public)")
            }
        }
        signals = currentSignals()
        updateBadge()
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = currentSignals()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refresh()
                self.observe()
            }
        }
    }

    private func currentSignals() -> [UUID: Signal] {
        model.sessionsByID.mapValues { session in
            switch session.runState {
            case .blocked: .blocked(askID: session.nextAsk?.id)
            case .failed: .failed
            default: .other
            }
        }
    }

    /// An ask answered in the app changes its session's signal, so its notification goes here too.
    private func refresh() {
        let current = currentSignals()
        for (id, signal) in current where signal != signals[id] {
            guard let session = model.sessionsByID[id] else { continue }
            switch signal {
            case .blocked(let askID?) where model.settings.notifiesWhenBlocked: notify(session, askID: askID)
            case .failed where model.settings.notifiesWhenFailed: notify(session, askID: nil)
            case .blocked(_?), .failed: withdraw(id)
            case .blocked(nil), .other: withdraw(id)
            }
        }
        for id in signals.keys where current[id] == nil { withdraw(id) }
        signals = current
        updateBadge()
    }

    private func updateBadge() {
        let count = model.blockedCount
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    private func notify(_ session: Session, askID: String?) {
        // One for an earlier ask goes first, so it can't linger while this one posts.
        withdraw(session.id)
        let content = UNMutableNotificationContent()
        let project = model.project(session.projectID)?.name
        content.title = [project, session.title].compactMap { $0 }.joined(separator: " · ")
        content.userInfo = ["session": session.id.uuidString, "ask": askID ?? ""]
        content.threadIdentifier = session.id.uuidString
        var category: UNNotificationCategory?
        if let ask = session.pendingAsks.first(where: { $0.id == askID }) {
            content.body = ask.kind.headline
            category = Self.category(for: ask)
        } else {
            content.body = "\(Glyph.failed) \(session.failureMessage ?? RunStateStyle.label(for: session.runState))"
        }
        content.sound = .default
        if let category {
            content.categoryIdentifier = category.identifier
            if categories[category.identifier] != category {
                categories[category.identifier] = category
                center.setNotificationCategories(Set(categories.values))
            }
        }
        let request = UNNotificationRequest(identifier: session.id.uuidString, content: content, trigger: nil)
        let id = session.id
        Task {
            // Reading the categories back waits for a new one to register, so its actions show.
            if category != nil { _ = await center.notificationCategories() }
            // Answered while that settled: nothing to post.
            if let askID, model.sessionsByID[id]?.nextAsk?.id != askID { return }
            do {
                try await center.add(request)
            } catch {
                Log.app.error("Posting a notification failed: \(error, privacy: .public)")
            }
        }
    }

    private func withdraw(_ id: UUID) {
        center.removeDeliveredNotifications(withIdentifiers: [id.uuidString])
        if categories.removeValue(forKey: "\(Action.questionCategory).\(id.uuidString)") != nil {
            center.setNotificationCategories(Set(categories.values))
        }
    }

    /// The actions an ask's notification offers, or nil for none: a secret, several questions or a
    /// multi-select question only open the session. A question with more than three options offers
    /// just Reply.
    private static func category(for ask: Ask) -> UNNotificationCategory? {
        switch ask.kind {
        case .permission(let permission):
            return permissionCategory(permission.offeredDecisions)
        case .question(let question):
            guard question.questions.count == 1, let only = question.questions.first, !only.multiSelect else { return nil }
            let options = only.options.count <= 3 ? only.options : []
            let actions = options.enumerated().map { UNNotificationAction(identifier: Action.option($0.offset), title: $0.element.label) }
            return UNNotificationCategory(
                identifier: "\(Action.questionCategory).\(ask.sessionID.uuidString)",
                actions: actions + [replyAction],
                intentIdentifiers: []
            )
        case .secret:
            return nil
        }
    }

    /// Allow once, Deny and Always in project, each only if offered. This session stays in the app.
    private static func permissionCategory(_ offered: [PermissionDecision]) -> UNNotificationCategory {
        let all: [(PermissionDecision, String)] = [(.allowOnce, "Allow once"), (.deny, "Deny"), (.allowAlwaysInProject, "Always in project")]
        let decisions = all.filter { offered.contains($0.0) }
        let actions = decisions.map { decision, title in
            UNNotificationAction(identifier: Action.decision(decision), title: title, options: decision == .deny ? .destructive : [])
        }
        return UNNotificationCategory(
            identifier: ([Action.permissionCategory] + decisions.map { Action.decision($0.0) }).joined(separator: "."),
            actions: actions + [replyAction],
            intentIdentifiers: []
        )
    }

    private static var replyAction: UNNotificationAction {
        UNTextInputNotificationAction(
            identifier: Action.reply,
            title: "Reply…",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Reply"
        )
    }

    /// A click opens the session. An action answers the ask it was posted for, if that's still the
    /// session's next ask, without bringing the app forward; one answered or expired since does nothing.
    private func respond(action: String, text: String?, sessionID: UUID, askID: String) {
        if action == UNNotificationDefaultActionIdentifier {
            model.reveal(.session(sessionID))
            return
        }
        guard !askID.isEmpty, let ask = model.sessionsByID[sessionID]?.nextAsk, ask.id == askID else { return }
        if action == Action.reply {
            guard let text, !text.allSatisfy(\.isWhitespace) else { return }
            // As if typed in the reply box.
            model.replyInWords(UserMessage(text: text), to: sessionID)
            return
        }
        switch ask.kind {
        case .permission(let permission):
            guard let decision = PermissionDecision(rawValue: action), permission.offeredDecisions.contains(decision) else { return }
            model.answer(ask: ask, with: .permission(decision))
        case .question(let question):
            guard question.questions.count == 1, let only = question.questions.first,
                  let index = only.options.indices.first(where: { Action.option($0) == action }) else { return }
            model.answer(ask: ask, with: .questions([only.id: [only.options[index].label]]))
        case .secret:
            return
        }
    }
}

extension AttentionCenter: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        guard let sessionID = (info["session"] as? String).flatMap(UUID.init(uuidString:)) else { return }
        let askID = info["ask"] as? String ?? ""
        let text = (response as? UNTextInputNotificationResponse)?.userText
        await respond(action: action, text: text, sessionID: sessionID, askID: askID)
    }
}
