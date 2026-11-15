import ConstellationCore
import SwiftUI

/// A card's jump badges: digits while ⌘ is held and letters after ⌘J at its top left, and the
/// letters of the pile ⌘ spread at its bottom left. The card draws them (see `PileCardView`), so
/// they ride it as it moves and drifts rather than trailing or jumping ahead of it.
struct JumpBadges: Equatable {
    struct Badge: Equatable {
        let label: String
        let typed: String
        /// A card in the pile ⌘ spread: cream rather than the keyboard's blue, so it reads apart
        /// from the pile numbers, and typed after letting go of ⌘.
        var isLetter = false
    }

    var top: Badge?
    var bottom: Badge?
}

extension AppModel {
    /// Every card's jump badges just now.
    func jumpBadges(in geometry: DesktopGeometry) -> [TileItem: JumpBadges] {
        var badges: [TileItem: JumpBadges] = [:]
        if let session = keyboard.hintSession {
            let spread = commandSpreadPile != nil
            for hint in session.hints where hint.label.hasPrefix(session.typed) && geometry.tileFrames[hint.item] != nil {
                // The ⌘-spread pile's letters stay where they were while ⌘ was held.
                if spread {
                    badges[hint.item, default: JumpBadges()].bottom = .init(label: hint.label, typed: session.typed, isLetter: true)
                } else {
                    badges[hint.item, default: JumpBadges()].top = .init(label: hint.label, typed: session.typed)
                }
            }
        } else if keyboard.showsDigitHints {
            let spreadHints = commandSpreadHints
            for hint in spreadHints where geometry.tileFrames[hint.item] != nil {
                badges[hint.item, default: JumpBadges()].bottom = .init(label: hint.label, typed: "", isLetter: true)
            }
            let typed = keyboard.typedDigits
            // Under a ⌘-spread pile, other piles' numbers would sit on its cards, so they give way.
            let spreadArea = spreadHints.compactMap { geometry.tileFrames[$0.item] }.reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -12, dy: -12)
            let spreadItems = Set(spreadHints.map(\.item))
            for (item, label) in zip(jumpTargets, JumpHints.digitLabels(count: jumpTargets.count)) where label.hasPrefix(typed) {
                guard let origin = geometry.badgeOrigin(of: item),
                      spreadItems.contains(item) || spreadArea.isNull || !spreadArea.contains(origin) else { continue }
                badges[item, default: JumpBadges()].top = .init(label: label, typed: typed)
            }
        }
        return badges
    }
}

/// A key chip with an ask-coloured edge so it stands out on a tile, with the letters already typed
/// dimmed. Lowercase, as you type them.
struct JumpBadge: View {
    let badge: JumpBadges.Badge

    var body: some View {
        let colour = badge.isLetter ? Palette.text : Palette.focus
        CornerChip(tint: colour.opacity(0.45)) {
            HStack(spacing: 0) {
                Text(badge.label.prefix(badge.typed.count)).foregroundStyle(Palette.textTertiary)
                Text(badge.label.dropFirst(badge.typed.count)).foregroundStyle(colour)
            }
        }
        .allowsHitTesting(false)
    }
}
