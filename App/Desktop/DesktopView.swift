import ConstellationCore
import SwiftUI
import UniformTypeIdentifiers

/// The whole desktop: the piles, the sidebar, and whatever sheet covers them.
struct DesktopView: View {
    @Environment(AppModel.self) private var model
    @Environment(DesktopAppearance.self) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDropTargeted = false
    /// The hidden sidebar, slid in while the pointer is on it.
    @State private var isSidebarPeeking = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Looks for each new project's icon as it arrives.
            Color.clear.task(id: model.projects.map(\.id)) { await model.findProjectIcons() }
            if appearance.drawsWallpaper {
                WallpaperBackdrop(image: appearance.wallpaper.image)
                    // Its credit, small in the corner, as the picture's licence asks.
                    .overlay(alignment: .bottomTrailing) {
                        if let background = appearance.background, !background.credit.isEmpty {
                            Text("\(background.title) · \(background.credit)")
                                .font(.ui(10))
                                .foregroundStyle(.white.opacity(0.45))
                                .shadow(color: .black.opacity(0.6), radius: 3)
                                .padding(10)
                        }
                    }
            } else {
                // Fully transparent pixels let clicks and drops fall through to the Finder,
                // so the empty desktop carries a fill you can't see.
                Color.black.opacity(0.002).ignoresSafeArea()
            }
            GeometryReader { proxy in
                PilesCanvas()
                    // Under a panel or sheet nothing on the desktop takes focus, so ⇥ stays inside it.
                    .disabled(model.isDesktopCovered)
                    .onAppear {
                        // The first real size replaces the model's default with nothing moving, so
                        // the piles don't spring into place at launch.
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            model.canvasWidth = proxy.size.width
                            model.canvasHeight = proxy.size.height
                        }
                        model.hasMeasuredCanvas = true
                    }
                    .onChange(of: proxy.size) { _, size in
                        model.canvasWidth = size.width
                        model.canvasHeight = size.height
                    }
            }
            if model.showsLauncher {
                EmptyStateLauncher()
            } else if model.isSidebarShown || isSidebarPeeking {
                Sidebar()
                    .disabled(model.isDesktopCovered)
                    .padding(16)
                    .onHover { if !$0 { withAnimation(.dismiss) { isSidebarPeeking = false } } }
                    .frame(maxHeight: .infinity, alignment: .top)
                    .transition(reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity))
            } else {
                // Hidden off screen; the pointer on the left edge slides it in.
                Color.clear
                    .frame(width: 4)
                    .frame(maxHeight: .infinity)
                    .contentShape(.rect)
                    // The same motion as showing it for good.
                    .onHover { if $0, !model.isDesktopCovered { withAnimation(.present) { isSidebarPeeking = true } } }
            }
            DesktopOverlays()
            if let onboarding = model.onboarding {
                OnboardingView(onboarding: onboarding)
                    .transition(.opacity)
            }
        }
        .animation(.layout, value: model.onboarding == nil)
        .overlay {
            // A folder dragged over the desktop: the keyboard's blue edge and what letting go does.
            if isDropTargeted {
                ZStack {
                    RoundedRectangle(cornerRadius: Radius.surface)
                        .strokeBorder(Palette.focus, lineWidth: 2)
                    Text("Drop to add as a project")
                        .font(.ui(13, weight: .medium))
                        .foregroundStyle(Palette.text)
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background(Palette.labelBackground, in: .capsule)
                        .overlay(Capsule().strokeBorder(Palette.focus.opacity(0.6)))
                }
                .padding(8)
                .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter { $0.hasDirectoryPath || (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            for folder in folders { model.addProject(at: folder) }
            return !folders.isEmpty
        } isTargeted: { isDropTargeted = $0 }
        .animation(.hover, value: model.showsLauncher)
        .environment(\.wallpaperTone, appearance.wallpaper.tone)
        .font(.ui())
        .foregroundStyle(Palette.text)
        .preferredColorScheme(.dark)
    }
}
