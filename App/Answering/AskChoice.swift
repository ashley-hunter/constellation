import ConstellationCore

/// One answer you can give with a single key or button: y/n/a/s for permissions, digits for the
/// options of a single question.
struct AskChoice: Identifiable, Hashable {
    let label: String
    /// For the tile, where four answers share 216 points.
    let shortLabel: String
    let key: String
    let answer: AskAnswer
    let weight: ConstellationButtonStyle.Weight

    var id: String { key }
}

extension Ask {
    var isPermission: Bool {
        if case .permission = kind { true } else { false }
    }

    var choices: [AskChoice] {
        switch kind {
        case .permission(let permission):
            let all: [(PermissionDecision, String, String, String, ConstellationButtonStyle.Weight)] = [
                (.allowOnce, "Allow once", "Allow", "y", .primary),
                (.deny, "Deny", "Deny", "n", .secondary),
                // Shifted, as it lasts beyond this ask.
                (.allowAlwaysInProject, "Always in project", "Always", "⇧A", .secondary),
                (.allowForSession, "This session", "Session", "s", .secondary),
            ]
            return all.filter { permission.offeredDecisions.contains($0.0) }
                .map { AskChoice(label: $0.1, shortLabel: $0.2, key: $0.3, answer: .permission($0.0), weight: $0.4) }
        case .question(let ask):
            guard ask.questions.count == 1, let question = ask.questions.first, !question.multiSelect else { return [] }
            return question.options.prefix(9).enumerated().map { index, option in
                AskChoice(
                    label: option.label,
                    shortLabel: option.label,
                    key: "\(index + 1)",
                    answer: .questions([question.id: [option.label]]),
                    weight: index == 0 ? .primary : index == 1 ? .secondary : .quiet
                )
            }
        case .secret:
            return []
        }
    }
}
