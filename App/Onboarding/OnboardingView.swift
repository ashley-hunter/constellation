import AppKit
import ConstellationCore
import SwiftUI

/// The first-run flow, full screen over the wallpaper. One decision per step in the column on the
/// left; on the right, a miniature of your desktop that answers every choice. The sample tiles are
/// one set of views throughout, so they fly from Welcome's constellation into the miniature and
/// rearrange from step to step, and Done grows the miniature into the real desktop.
struct OnboardingView: View {
    let onboarding: Onboarding
    @Environment(DesktopAppearance.self) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var namespace
    @State private var arrived = false
    @State private var commandHold = CommandHoldMonitor()

    var body: some View {
        GeometryReader { proxy in
            let layout = OnboardingLayout(size: proxy.size)
            let scene = OnboardingScene(layout: layout, onboarding: onboarding, arrived: arrived || reduceMotion)
            ZStack(alignment: .topLeading) {
                OnboardingBackdrop(image: appearance.wallpaper.image, step: onboarding.step, isExpanding: onboarding.isExpanding)
                if onboarding.step != .welcome {
                    MiniDesktopChrome(layout: layout, onboarding: onboarding, wallpaper: appearance.wallpaper.image, keepsSidebar: scene.landsOnProjects)
                        .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.96)))
                }
                if onboarding.step == .welcome {
                    ConstellationLinks(tiles: scene.tiles, isDrawn: arrived)
                        .transition(.opacity)
                }
                GhostLayer(scene: scene, onboarding: onboarding, reduceMotion: reduceMotion)
                    .id(reduceMotion ? onboarding.step.rawValue : 0)
                    .transition(.opacity)
                SceneOverlays(scene: scene, onboarding: onboarding)
                if onboarding.step == .welcome {
                    WelcomeHero(onboarding: onboarding, namespace: namespace, reduceMotion: reduceMotion)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .transition(.opacity)
                } else {
                    StepColumn(onboarding: onboarding, namespace: namespace, reduceMotion: reduceMotion)
                        .frame(width: OnboardingLayout.columnWidth, alignment: .leading)
                        .position(x: layout.columnX + OnboardingLayout.columnWidth / 2, y: proxy.size.height / 2)
                        .opacity(onboarding.isExpanding ? 0 : 1)
                        .animation(.easeOut(duration: 0.12), value: onboarding.isExpanding)
                        .transition(.opacity)
                }
                OnboardingFooter(onboarding: onboarding)
                    .frame(width: proxy.size.width)
                    .position(x: proxy.size.width / 2, y: proxy.size.height - 40)
                    .opacity(onboarding.isExpanding ? 0 : 1)
                    .animation(.easeOut(duration: 0.12), value: onboarding.isExpanding)
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.25) : .onboarding, value: onboarding.step)
            .animation(.spring(response: 0.6, dampingFraction: 0.9), value: onboarding.isExpanding)
        }
        .environment(\.onboardingInk, OnboardingInk(hue: appearance.wallpaper.hue))
        .ignoresSafeArea()
        .contentShape(.rect)
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            guard !folders.isEmpty else { return false }
            onboarding.addFolders(folders)
            return true
        }
        .onAppear {
            commandHold.start(onboarding)
            guard !reduceMotion else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(120))
                arrived = true
            }
        }
        .onDisappear { commandHold.stop() }
    }
}

// MARK: Backdrop

/// Your wallpaper, frosted and darkened: lightly on Welcome, more once there's reading to do, and
/// clearing as Done hands over to the desktop.
private struct OnboardingBackdrop: View {
    let image: CGImage?
    let step: OnboardingStep
    let isExpanding: Bool

    var body: some View {
        ZStack {
            Color(hex: 0x0E0D0C)
            if let image {
                Color.clear
                    .overlay {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .blur(radius: isExpanding ? 0 : step == .welcome ? 22 : 48)
                            .scaleEffect(1.08)
                    }
                    .clipped()
            }
            LinearGradient(colors: [.black.opacity(0.32), .black.opacity(0.58)], startPoint: .top, endPoint: .bottom)
                .opacity(isExpanding ? 0 : step == .welcome ? 0.85 : 1)
            RadialGradient(colors: [Color(hex: 0xE5A94F, opacity: 0.10), .clear], center: UnitPoint(x: 0.5, y: 0.42), startRadius: 0, endRadius: 720)
                .opacity(step == .welcome && !isExpanding ? 1 : 0)
            Color(hex: 0x0E0D0C).opacity(isExpanding ? 0 : step == .welcome ? 0.1 : 0.32)
        }
        // Stays opaque through Done's zoom, so the real desktop shows only as the whole view fades.
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: step == .welcome)
    }
}

// MARK: Miniature

/// The miniature's wallpaper and sidebar, drawn at desktop size and scaled into its frame.
private struct MiniDesktopChrome: View {
    let layout: OnboardingLayout
    let onboarding: Onboarding
    let wallpaper: CGImage?
    /// Done's zoom lands where the real sidebar is, so the sketch hands over to it instead of fading early.
    let keepsSidebar: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let rect = layout.desktopRect(expanded: onboarding.zoomsIntoDesktop)
        let scale = rect.width / max(layout.size.width, 1)
        ZStack(alignment: .topLeading) {
            if onboarding.model.isSidebarShown {
                MiniSidebar(onboarding: onboarding)
                    .frame(width: 248, height: layout.size.height - 32)
                    .offset(x: 16, y: 16)
                    .opacity(onboarding.isExpanding && !keepsSidebar ? 0 : 1)
            }
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
        .scaleEffect(scale, anchor: .topLeading)
        .frame(width: rect.width, height: rect.height, alignment: .topLeading)
        // Drawn at the miniature's own size, as shrinking a full-size wallpaper with a scale effect
        // leaves it rough and banded.
        .background {
            ZStack {
                if let wallpaper {
                    Image(decorative: wallpaper, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                } else {
                    Color(hex: 0x1A1816)
                }
                Color.black.opacity(onboarding.isExpanding ? 0 : 0.18)
            }
            .frame(width: rect.width, height: rect.height)
            .clipped()
        }
        .clipShape(.rect(cornerRadius: onboarding.isExpanding ? 0 : 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: onboarding.isExpanding ? 0 : 14, style: .continuous)
                .strokeBorder(.white.opacity(onboarding.isExpanding ? 0 : 0.16))
        }
        .shadow(color: .black.opacity(onboarding.isExpanding ? 0 : 0.5), radius: 40, y: 24)
        .phaseAnimator([false, true, false], trigger: onboarding.summonCount) { view, isLit in
            // ⌥Space on the keyboard step: the miniature lights up as the real desktop would come forward.
            view
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Palette.ask, lineWidth: 2.5)
                        .shadow(color: Palette.ask.opacity(0.8), radius: 18)
                        .opacity(isLit ? 1 : 0)
                }
                .scaleEffect(isLit && !reduceMotion ? 1.02 : 1)
        } animation: { _ in .spring(response: 0.28, dampingFraction: 0.7) }
        .position(x: rect.midX, y: rect.midY)
        .opacity(onboarding.isExpanding && !onboarding.zoomsIntoDesktop ? 0 : 1)
        .allowsHitTesting(false)
    }
}

/// A sketch of the real sidebar: filters, and the projects you've chosen.
private struct MiniSidebar: View {
    let onboarding: Onboarding

    var body: some View {
        // Drawn larger than the real sidebar so it still reads at miniature scale.
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ConstellationMark().frame(width: 24, height: 24).opacity(0.85)
                Text("Constellation").font(.ui(22, weight: .semibold)).foregroundStyle(Palette.text)
            }
            .padding(.bottom, 18)
            ForEach(["All", "Needs you", "Working", "Done"], id: \.self) { filter in
                Text(filter).font(.ui(20)).foregroundStyle(Palette.textSecondary).frame(height: 40)
            }
            Text("Projects").font(.ui(17, weight: .semibold)).foregroundStyle(Palette.textTertiary).padding(.top, 20)
            ForEach(Array(onboarding.chosenProjects.prefix(8).enumerated()), id: \.element.id) { index, choice in
                HStack(spacing: 10) {
                    SwatchMark(swatch: ProjectSwatch.allCases[index % ProjectSwatch.allCases.count], size: 14)
                    Text(choice.name).font(.ui(19)).foregroundStyle(Palette.text).lineLimit(1)
                }
                .frame(height: 40)
                .transition(.opacity.combined(with: .move(edge: .leading)))
            }
            Spacer()
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .panelSurface(cornerRadius: 14)
        .animation(.onboarding, value: onboarding.chosenProjects)
    }
}

// MARK: Ghosts

private struct GhostLayer: View {
    let scene: OnboardingScene
    let onboarding: Onboarding
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(paused: onboarding.step != .welcome || reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            ZStack(alignment: .topLeading) {
                ForEach(Ghost.all) { ghost in
                    let placement = scene.tiles[ghost.id]
                    let drift = onboarding.step == .welcome && !reduceMotion
                        ? CGSize(width: sin(time * 0.32 + Double(ghost.id) * 1.7) * 7, height: cos(time * 0.27 + Double(ghost.id) * 2.3) * 6)
                        : .zero
                    GhostTileView(ghost: ghost, placement: placement, settings: onboarding.settings)
                        .scaleEffect(placement.frame.width / Ghost.designSize.width)
                        .rotationEffect(.degrees(placement.tilt))
                        .zIndex(placement.layer)
                        .position(x: placement.frame.midX, y: placement.frame.midY)
                        .offset(drift)
                        .opacity(onboarding.isExpanding ? 0 : placement.opacity)
                        .animation(animation(for: ghost.id), value: placement)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func animation(for index: Int) -> Animation {
        if reduceMotion { return .easeInOut(duration: 0.2) }
        if onboarding.step == .welcome { return .spring(response: 1.15, dampingFraction: 0.82).delay(0.05 + Double(index) * 0.07) }
        return .onboarding.delay(Double(index) * 0.022)
    }
}

/// Faint lines between Welcome's tiles, drawn once they've settled.
private struct ConstellationLinks: View {
    let tiles: [GhostPlacement]
    let isDrawn: Bool

    static let pairs = [(7, 0), (0, 1), (6, 7), (2, 3), (3, 4), (4, 5)]

    var body: some View {
        ZStack {
            Path { path in
                for (from, to) in Self.pairs where tiles.indices.contains(from) && tiles.indices.contains(to) {
                    path.move(to: CGPoint(x: tiles[from].frame.midX, y: tiles[from].frame.midY))
                    path.addLine(to: CGPoint(x: tiles[to].frame.midX, y: tiles[to].frame.midY))
                }
            }
            .trim(from: 0, to: isDrawn ? 1 : 0)
            .stroke(Palette.text.opacity(0.22), style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [2, 5]))
            .animation(.easeOut(duration: 1.4).delay(1.1), value: isDrawn)
            StarField()
                .opacity(isDrawn ? 1 : 0)
                .animation(.easeOut(duration: 1.6).delay(0.4), value: isDrawn)
        }
        .allowsHitTesting(false)
    }
}

/// Small stars that twinkle behind Welcome.
private struct StarField: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { context in
            Canvas { canvas, size in
                let time = context.date.timeIntervalSinceReferenceDate
                var generator = SeededGenerator(seed: 7)
                for index in 0..<46 {
                    let point = CGPoint(x: Double.random(in: 0...1, using: &generator) * size.width, y: Double.random(in: 0...1, using: &generator) * size.height)
                    let radius = Double.random(in: 0.6...1.6, using: &generator)
                    let phase = Double.random(in: 0...(2 * .pi), using: &generator)
                    let alpha = 0.18 + 0.32 * (0.5 + 0.5 * sin(time * 0.9 + phase + Double(index)))
                    canvas.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)), with: .color(Palette.text.opacity(alpha)))
                }
            }
        }
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

/// Island labels, the empty-miniature hint and the sample notification, placed like the ghosts.
private struct SceneOverlays: View {
    let scene: OnboardingScene
    let onboarding: Onboarding

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(scene.labels) { label in
                let origin = scene.labelOrigin(label)
                HStack(spacing: 8) {
                    if let swatch = label.swatch { SwatchMark(swatch: swatch, size: 16) }
                    Text(label.text).font(.ui(26, weight: .medium)).foregroundStyle(Palette.text)
                    if let status = label.status {
                        Text(status).font(.ui(22, weight: .medium)).foregroundStyle(label.statusColor)
                    }
                }
                .shadow(color: .black.opacity(0.5), radius: 6)
                .fixedSize()
                .scaleEffect(scene.scale * label.size, anchor: .topLeading)
                .offset(x: origin.x, y: origin.y)
                // New labels wait for the tiles to fly in under them; old ones leave at once.
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 8)).animation(.onboarding.delay(0.28)),
                    removal: .opacity.animation(.easeOut(duration: 0.12))
                ))
            }
            if let message = scene.emptyMessage {
                let rect = scene.layout.desktopRect(expanded: onboarding.zoomsIntoDesktop)
                HStack(spacing: 8) {
                    Image(systemName: "square.dashed").font(.system(size: 13, weight: .medium))
                    Text(message).font(.ui(13, weight: .medium))
                }
                .foregroundStyle(Palette.text.opacity(0.85))
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(.ultraThinMaterial, in: .capsule)
                .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
                // In the middle of the room beside the miniature's sidebar, when it shows one.
                .position(x: rect.midX + (onboarding.model.isSidebarShown ? 140 * rect.width / max(scene.layout.size.width, 1) : 0), y: rect.midY)
                .transition(.opacity)
            }
            if scene.showsBanner {
                let frame = scene.bannerFrame
                SampleNotification(project: scene.tiles.indices.contains(1) ? scene.tiles[1].project ?? "ledger" : "ledger")
                    .frame(width: 360, height: 76)
                    .scaleEffect(frame.width / 360, anchor: .topLeading)
                    .offset(x: frame.minX, y: frame.minY)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.onboarding, value: scene.labels)
        .animation(.onboarding.delay(0.25), value: scene.showsBanner)
        .opacity(onboarding.isExpanding && !scene.landsOnProjects ? 0 : 1)
        .animation(.easeOut(duration: 0.3), value: onboarding.isExpanding)
        .allowsHitTesting(false)
    }
}

/// What a blocked session's notification looks like.
private struct SampleNotification: View {
    let project: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AppIconMark(size: 38)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Add CSV export needs you").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    Spacer()
                    Text("now").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                }
                Text("\(project) · Edit package.json? Adds papaparse 5.4").font(.system(size: 12)).foregroundStyle(.white.opacity(0.8)).lineLimit(2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: .rect(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.14)))
        .environment(\.colorScheme, .dark)
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    }
}

// MARK: Column

private struct WelcomeHero: View {
    @Environment(\.onboardingInk) private var ink
    let onboarding: Onboarding
    let namespace: Namespace.ID
    let reduceMotion: Bool

    var body: some View {
        VStack(spacing: 0) {
            AppIconMark(size: 112)
            Text("Constellation")
                .font(.ui(76, weight: .semibold))
                .tracking(-1.8)
                .foregroundStyle(ink.primary)
                .shadow(color: .black.opacity(0.35), radius: 24, y: 6)
                .padding(.top, 30)
            Text(OnboardingStep.welcome.subtitle)
                .font(.ui(19))
                .foregroundStyle(ink.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 540)
                .padding(.top, 14)
            Button(action: onboarding.advance) {
                HStack(spacing: 8) {
                    Text("Get started")
                    Image(systemName: "arrow.right")
                }
            }
            .buttonStyle(ContinueButtonStyle())
            .onboardingMatched("continue", in: namespace, enabled: !reduceMotion)
            .padding(.top, 40)
            Button("Skip for now", action: onboarding.skip)
                .buttonStyle(ConstellationButtonStyle(weight: .quiet, tint: ink.secondary))
                .padding(.top, 12)
        }
        .padding(.bottom, 40)
    }
}

private struct StepColumn: View {
    @Environment(\.onboardingInk) private var ink
    let onboarding: Onboarding
    let namespace: Namespace.ID
    let reduceMotion: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(onboarding.step.title)
                        .font(.ui(40, weight: .semibold))
                        .tracking(-0.8)
                        .foregroundStyle(ink.primary)
                    Text(onboarding.step.subtitle)
                        .font(.ui(16))
                        .foregroundStyle(ink.secondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .id(onboarding.step)
                .transition(slide)
            }
            ZStack(alignment: .topLeading) {
                StepCard(onboarding: onboarding)
                    .id(onboarding.step)
                    .transition(slide)
            }
            .padding(.top, 28)
            controls
                .padding(.top, 24)
        }
    }

    private var slide: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let distance = 36.0 * Double(onboarding.direction)
        return .asymmetric(
            insertion: .offset(x: distance).combined(with: .opacity),
            removal: .offset(x: -distance).combined(with: .opacity)
        )
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: 10) {
            Button(action: onboarding.back) { Image(systemName: "arrow.left") }
                .buttonStyle(RoundIconButtonStyle())
                .accessibilityLabel("Back")
            if onboarding.step == .done {
                if onboarding.canStartSession {
                    Button { onboarding.finish(startingSession: true) } label: {
                        HStack(spacing: 8) {
                            Text("Start a session")
                            Image(systemName: "arrow.right")
                        }
                    }
                    .buttonStyle(ContinueButtonStyle())
                    .onboardingMatched("continue", in: namespace, enabled: !reduceMotion)
                    Button("Go to the desktop") { onboarding.finish(startingSession: false) }
                        .buttonStyle(ContinueButtonStyle(isProminent: false))
                } else {
                    Button { onboarding.finish(startingSession: false) } label: {
                        HStack(spacing: 8) {
                            Text("Go to the desktop")
                            Image(systemName: "arrow.right")
                        }
                    }
                    .buttonStyle(ContinueButtonStyle())
                    .onboardingMatched("continue", in: namespace, enabled: !reduceMotion)
                }
            } else {
                Button(action: onboarding.advance) {
                    HStack(spacing: 8) {
                        Text(onboarding.continuesWithoutProjects ? "Continue without projects" : "Continue")
                        Image(systemName: "arrow.right")
                    }
                }
                .buttonStyle(ContinueButtonStyle())
                .disabled(!onboarding.canContinue)
                .onboardingMatched("continue", in: namespace, enabled: !reduceMotion)
                Spacer()
                if onboarding.step != .agents {
                    Button("Skip for now", action: onboarding.skip)
                        .buttonStyle(ConstellationButtonStyle(weight: .quiet, tint: ink.secondary))
                }
            }
        }
    }
}

/// Progress pills and the keys that move through the flow.
private struct OnboardingFooter: View {
    @Environment(\.onboardingInk) private var ink
    let onboarding: Onboarding

    var body: some View {
        VStack(spacing: 14) {
            if onboarding.step != .welcome {
                StepProgress(step: onboarding.step)
                    .transition(.opacity)
            }
            HStack(spacing: 16) {
                hint("↵", onboarding.step == .welcome ? "get started" : onboarding.step == .done ? (onboarding.canStartSession ? "start a session" : "finish") : "continue")
                if onboarding.step != .welcome { hint("esc", "back") }
                switch onboarding.step {
                case .agents, .permissions: hint("← →", "choose"); hint("space", "fix")
                case .projects: hint("↑ ↓ ← →", "choose"); hint("space", "toggle")
                case .background: hint("↑ ↓ ← →", "choose")
                case .defaults: hint("↑ ↓", "setting"); hint("← →", "change")
                default: EmptyView()
                }
            }
        }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            KeyChip(key)
            Text(label).font(.ui(12)).foregroundStyle(ink.tertiary)
        }
    }
}

/// Holding ⌘ for a quarter of a second shows number hints on the keyboard step's miniature.
@MainActor
private final class CommandHoldMonitor {
    private var monitor: Any?
    private var pending: Task<Void, Never>?

    func start(_ onboarding: Onboarding) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self, weak onboarding] event in
            let isHeld = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
            MainActor.assumeIsolated {
                guard let self, let onboarding, onboarding.step == .keyboard else { return }
                self.pending?.cancel()
                if isHeld {
                    self.pending = Task {
                        try? await Task.sleep(for: .milliseconds(250))
                        guard !Task.isCancelled else { return }
                        onboarding.showsDigitHints = true
                    }
                } else {
                    onboarding.showsDigitHints = false
                }
            }
            return event
        }
    }

    func stop() {
        pending?.cancel()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
