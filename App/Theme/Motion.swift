import AppKit
import ConstellationCore
import SwiftUI

/// Motion as quick as Hyprland's but on springs, so anything moving can be sent back mid-flight
/// and turn around from where it is, keeping its speed. Panels open in about a quarter of a second
/// and close a little quicker; hovers and small fades take about a seventh.
///
/// One token for each kind of change, given once with `withAnimation` where the model changes, so
/// a change moves on one spring rather than on whichever implicit animation catches it. Views keep
/// implicit animations to their own looks (`.animation(_:body:)`), never to where things are.
/// Under Reduce Motion the fan and the layout take a fade's short time, panels fade in place
/// rather than grow (`PresentationEffect`), and drift, breathing and the nudge stop.
extension Animation {
    /// Hyprland's easeOutQuint, cubic-bezier(0.23, 1, 0.32, 1).
    static func easeOutQuint(_ duration: Double) -> Animation { .timingCurve(0.23, 1, 0.32, 1, duration: duration) }

    /// Hovers, presses, small swaps and scrolls.
    static let hover = Animation.spring(duration: 0.16, bounce: 0)
    /// Small fades in and out, and one panel crossfading into another.
    static let fadeIn = Animation.spring(duration: 0.14, bounce: 0)
    static let fadeOut = Animation.spring(duration: 0.12, bounce: 0)
    /// A pile spreading on hover or a click and gathering back, a card dragged into place, and the
    /// looks that change with them: quick, so it never holds you up.
    @MainActor static var fan: Animation { Motion.reducesMotion ? fadeOut : .spring(duration: 0.18, bounce: 0) }
    /// Cards and piles moving to new places: the desktop re-flowing.
    @MainActor static var layout: Animation { Motion.reducesMotion ? fadeOut : .spring(duration: 0.26, bounce: 0) }
    /// A panel, sheet, session view or the sidebar coming in, a panel growing out of its card, or
    /// changing size.
    static let present = Animation.spring(duration: 0.26 * slowMotion, bounce: 0)
    /// The same going away: a little quicker than it came.
    static let dismiss = Animation.spring(duration: 0.2 * slowMotion, bounce: 0)
    /// `-ConstellationSlowMotion 6` stretches panels opening and closing, for watching them.
    private static let slowMotion = max(1, UserDefaults.standard.double(forKey: "ConstellationSlowMotion"))
    /// A cue on a card appearing, such as the amber edge of one that needs you: quick in, to catch
    /// the eye. The done glint and the nudge are keyframed on its timing.
    static let cue = Animation.easeOut(duration: 0.25)
    /// Ambient motion coming to rest, as a pile's drift eases back when it stops swaying.
    static let ambient = Animation.easeOut(duration: 0.4)

    // The old names, for code not yet moved to the ones above.
    static var constellation: Animation { hover }
    @MainActor static var constellationSlow: Animation { layout }
    static var panelOpen: Animation { present }
    static var panelClose: Animation { dismiss }
}

enum Motion {
    /// Reduce Motion is on in System Settings, read where a model change picks its token.
    @MainActor static var reducesMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

/// How an overlay comes and goes: Hyprland's popin, or grown out of the tile it opens from.
enum PresentationStyle: Equatable {
    /// A uniform scale up from 87% and a fade.
    case popin
    /// The tile's frame carries straight into the panel's: a uniform scale from the tile's width
    /// while its surface is revealed from the tile's height, so it never squishes. Both rects are in
    /// the overlay's container, where the panel is laid out at `to`, and come from layout, never
    /// from a measured frame the animation itself moves.
    case hero(from: CGRect, to: CGRect)
}

/// Places an overlay between closed (0) and open (1). The progress and the hero's rects are
/// animatable, so a spring driving them can be turned around at any point and carries on from where
/// the overlay is, and a card that moves while its panel grows or shrinks is followed smoothly.
struct PresentationEffect: ViewModifier, Animatable {
    var progress: Double
    let isHero: Bool
    var source: CGRect
    var target: CGRect
    /// The card's face, drawn over the growing panel and faded out as it grows, so the card turns
    /// into the panel rather than swapping for it.
    var standIn: AnyView?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(progress: Double, style: PresentationStyle, standIn: AnyView? = nil) {
        self.progress = progress
        self.standIn = standIn
        switch style {
        case .popin:
            (isHero, source, target) = (false, .zero, .zero)
        case .hero(let from, let to):
            (isHero, source, target) = (true, from, to)
        }
    }

    nonisolated var animatableData: AnimatablePair<Double, AnimatablePair<CGRect.AnimatableData, CGRect.AnimatableData>> {
        get { AnimatablePair(progress, AnimatablePair(source.animatableData, target.animatableData)) }
        set {
            progress = newValue.first
            source.animatableData = newValue.second.first
            target.animatableData = newValue.second.second
        }
    }

    func body(content: Content) -> some View {
        let progress = min(max(progress, 0), 1)
        if reduceMotion {
            // Nothing grows or scales: the panel fades in and out where it stands.
            content.opacity(progress)
        } else if isHero {
            let metrics = HeroMetrics(source: source, target: target)
            let scale = metrics.startScale + (1 - metrics.startScale) * progress
            // The corner as drawn goes from the card's to the panel's; the reveal is in the panel's
            // own points, before the scale.
            let corner = metrics.startCorner + (PanelSurface.cornerRadius - metrics.startCorner) * progress
            content
                // The panel's surface draws only this much, with its shadow, until it has grown.
                .environment(\.panelReveal, progress >= 0.999 ? nil : PanelReveal(
                    height: metrics.startHeight + (target.height - metrics.startHeight) * progress,
                    cornerRadius: corner / scale
                ))
                // Laid out at the size it shows at, as a card is, so its text stays its own size
                // rather than growing with the panel; gone by under half way.
                .overlay(alignment: .topLeading) {
                    if let standIn, progress < 0.5 {
                        let revealed = CGSize(width: target.width, height: metrics.startHeight + (target.height - metrics.startHeight) * progress)
                        let shown = CGSize(width: revealed.width * scale, height: revealed.height * scale)
                        let shrink = min(1, shown.width / TileMetrics.fullSize.width)
                        standIn
                            .environment(\.cardSize, CGSize(width: shown.width / shrink, height: shown.height / shrink))
                            .frame(width: shown.width / shrink, height: shown.height / shrink, alignment: .topLeading)
                            .scaleEffect(shrink / scale, anchor: .topLeading)
                            .frame(width: revealed.width, height: revealed.height, alignment: .topLeading)
                            .clipShape(.rect(cornerRadius: corner / scale, style: .continuous))
                            .offset(x: target.minX, y: target.minY)
                            .opacity(1 - Self.smoothstep(progress / 0.45))
                            .allowsHitTesting(false)
                    }
                }
                // Scaled about the container's corner, then moved so the panel's corner runs straight
                // from the card's to its own. Opaque throughout: the card is hidden while it stands in.
                .scaleEffect(scale, anchor: .topLeading)
                .offset(
                    x: source.minX + (target.minX - source.minX) * progress - target.minX * scale,
                    y: source.minY + (target.minY - source.minY) * progress - target.minY * scale
                )
        } else {
            content
                .scaleEffect(0.87 + 0.13 * progress)
                .opacity(progress)
        }
    }
}

extension EnvironmentValues {
    /// False while the overlay around this view is opening or closing, for content that can't move
    /// with it, such as a terminal's Metal view. Set by `OverlayPresenter`.
    @Entry var presentationIsSettled = true
}

extension PresentationEffect {
    static func smoothstep(_ value: Double) -> Double {
        let x = min(max(value, 0), 1)
        return x * x * (3 - 2 * x)
    }
}

/// The hero's geometry: the scale from the tile's width to the panel's, the clip's height in the
/// panel's own points, from the tile's height to the panel's, and the card's corner as drawn.
@MainActor
private struct HeroMetrics {
    let startScale: Double
    let startHeight: Double
    let startCorner: Double

    init(source: CGRect, target: CGRect) {
        startScale = target.width > 0 ? max(source.width / target.width, 0.01) : 1
        startHeight = min(target.height, source.height / startScale)
        // Cards are drawn at full size and scaled to their frame, corner and all.
        startCorner = PanelSurface.cornerRadius * min(1, source.width / TileMetrics.fullSize.width)
    }
}
