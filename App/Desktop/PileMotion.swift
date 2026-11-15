import ConstellationCore
import SwiftUI

/// A pile at rest sways a point or two over several seconds, its cards and label together, so the
/// desktop doesn't sit dead still. Every view of a pile reads the same clock, so they move as one;
/// each pile has its own way, pace and phase, from its key, so piles never move in step. The offset
/// is a render effect, so the cards themselves aren't redrawn as they go. It holds still while the
/// app is in the background, and eases back to rest when it stops.
struct PileDrift: ViewModifier {
    let pile: Pile.ID
    let isOn: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(DesktopAppearance.self) private var appearance

    func body(content: Content) -> some View {
        let drifts = isOn && !reduceMotion
        // A point or two over seconds needs no more than a few frames a second to look smooth.
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !drifts || !appearance.isActive)) { context in
            content.animation(.ambient) { content in
                content.modifier(DriftOffset(amount: drifts ? 1 : 0, away: away(at: context.date)))
            }
        }
    }

    /// Where the pile has swayed to at `date`: easing out to its furthest and back over two periods.
    private func away(at date: Date) -> CGSize {
        let cycle = 2 * period
        let time = (date.timeIntervalSinceReferenceDate + unit(4) * period).truncatingRemainder(dividingBy: cycle)
        let along = (1 - cos(2 * .pi * time / cycle)) / 2
        return CGSize(width: unit(1) * 2 * along, height: unit(2) * 1.5 * along)
    }

    /// Stable values in -1...1 from the pile's key: FNV-1a, as `hashValue` changes every launch.
    private func unit(_ salt: UInt64) -> Double {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325 ^ salt
        for byte in pile.key.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return Double(hash % 2001) / 1000 - 1
    }

    private var period: Double { 9 + unit(3) * 2 }
}

/// The sway, scaled by `amount` so stopping and starting ease rather than jump; only the amount
/// animates, while the clock moves the sway itself.
private struct DriftOffset: ViewModifier, Animatable {
    var amount: Double
    let away: CGSize

    nonisolated var animatableData: Double {
        get { amount }
        set { amount = newValue }
    }

    func body(content: Content) -> some View {
        content.offset(x: away.width * amount, y: away.height * amount)
    }
}

/// What a card's state asks of you, drawn on it. Needing you: a warm light inside the card from its
/// top edge, as if lit from above, with one soft pulse as it starts, then still; the card's own question
/// band (`InPlaceAnswer`) says what it wants. Finishing (a turn done, a shell's command ended): one
/// green glint round its edge. Reduce Motion drops the pulse and the glint. The nudge is
/// `CardNudge`, round the whole card.
struct StateCue: ViewModifier {
    let rank: PileRank
    /// The card can be seen in full: a pile's top, or spread.
    let isShown: Bool
    /// Its panel stands in for it, so nothing is drawn round its empty place.
    var isOpened = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Bumped by each finish, which runs the glint's keyframes once.
    @State private var glints = 0
    /// Bumped as the card starts needing you, which runs the pulse once.
    @State private var pulses = 0

    func body(content: Content) -> some View {
        let waits = rank == .needsYou && !isOpened
        let shape = RoundedRectangle(cornerRadius: PanelSurface.cornerRadius, style: .continuous)
        content
            .keyframeAnimator(initialValue: 0.0, trigger: pulses) { content, light in
                content.background {
                    shape.fill(Palette.popover)
                        .shadow(color: Palette.ask.opacity(0.7 * light), radius: 18)
                        .opacity(light > 0 ? 1 : 0)
                }
            } keyframes: { _ in
                // Up over a beat, then gone over a second and a half.
                KeyframeTrack {
                    CubicKeyframe(1, duration: 0.35)
                    CubicKeyframe(0, duration: 1.5)
                }
            }
            .overlay {
                // Behind another too, so a stack shows each card waiting where its edge peeks out.
                // It comes in on the cue's timing as the card starts needing you.
                GeometryReader { proxy in
                    ZStack(alignment: .top) {
                        // Added to the card's own colours, so it lights the surface and its text alike.
                        EllipticalGradient(
                            colors: [Palette.ask.opacity(0.3), Palette.ask.opacity(0.06), .clear],
                            center: .top, startRadiusFraction: 0, endRadiusFraction: 0.55
                        )
                        .frame(width: proxy.size.width * 1.3, height: proxy.size.height * 1.1)
                        .blendMode(.plusLighter)
                        // The edge the light falls over.
                        Rectangle().fill(Palette.ask.opacity(0.55)).frame(height: 1)
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                }
                .clipShape(shape)
                .animation(.cue) { $0.opacity(waits ? 1 : 0) }
                .allowsHitTesting(false)
            }
            .keyframeAnimator(initialValue: 0.0, trigger: glints) { content, glint in
                content.overlay {
                    shape.strokeBorder(Palette.done, lineWidth: 2)
                        .shadow(color: Palette.done, radius: 10)
                        .opacity(glint)
                        .allowsHitTesting(false)
                }
            } keyframes: { _ in
                // Up quickly, held a beat, then gone over a second.
                KeyframeTrack {
                    CubicKeyframe(1, duration: 0.25)
                    LinearKeyframe(1, duration: 0.65)
                    CubicKeyframe(0, duration: 1)
                }
            }
            .onChange(of: rank) { old, new in
                guard isShown, !isOpened, !reduceMotion else { return }
                if new == .needsYou, old != .needsYou { pulses += 1 }
                if old == .working, new == .unseenDone || new == .seen { glints += 1 }
            }
    }
}

/// One small nudge as a card starts needing you, the whole card with its chips, and never again
/// just because it shows again. A setting; Reduce Motion drops it.
struct CardNudge: ViewModifier {
    let rank: PileRank
    /// The card can be seen in full: a pile's top, or spread.
    let isShown: Bool
    let isOn: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var nudges = 0

    func body(content: Content) -> some View {
        content
            .keyframeAnimator(initialValue: 0.0, trigger: nudges) { content, angle in
                content.rotationEffect(.degrees(angle))
            } keyframes: { _ in
                KeyframeTrack {
                    // A beat first, so a card that moved as it changed has settled before it nudges.
                    LinearKeyframe(0, duration: 0.4)
                    CubicKeyframe(1.2, duration: 0.09)
                    CubicKeyframe(-1, duration: 0.14)
                    CubicKeyframe(0, duration: 0.16)
                }
            }
            .onChange(of: rank) { old, new in
                guard new == .needsYou, old != .needsYou, isShown, isOn, !reduceMotion else { return }
                nudges += 1
            }
    }
}
