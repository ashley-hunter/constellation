import SwiftUI

/// The one surface for panels, tiles, sheets and the palette, from Sort UI ("Sort shape, light
/// glass"): the popover fill at 88% over a light material, a crisp 1 pt edge drawn just outside,
/// and a soft two-layer shadow. Under Reduce Transparency the fill is solid. While a panel grows
/// out of a tile, `panelReveal` shows only its top, and the fill, edge and shadow follow that
/// shape, so the shadow travels with the panel every frame.
struct PanelSurface: ViewModifier {
    enum Depth {
        /// Tiles and small bars: Sort's light card shadow.
        case card
        /// Panels over the desktop: Sort's dialog shadow, stronger so a dark panel still lifts off
        /// a busy wallpaper, with a faint ambient ring.
        case panel
    }

    static let cornerRadius = Radius.surface

    var cornerRadius = PanelSurface.cornerRadius
    var depth = Depth.panel
    var edge = Palette.edge
    @Environment(\.panelReveal) private var reveal

    func body(content: Content) -> some View {
        let shape = RevealedRect(height: reveal?.height, cornerRadius: reveal?.cornerRadius ?? cornerRadius)
        content
            // Surfaces inside this one are whole.
            .environment(\.panelReveal, nil)
            .clipShape(shape)
            .background {
                PanelFill(shape: shape).modifier(SurfaceShadow(depth: depth))
            }
            .overlay { shape.inset(by: -0.5).stroke(edge, lineWidth: 1).allowsHitTesting(false) }
    }
}

/// A panel's glass on its own, for a surface that draws its own edge (the split screen's empty
/// slot): the popover fill at 88% over a light material, solid under Reduce Transparency.
struct PanelFill<S: Shape>: View {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            if reduceTransparency {
                shape.fill(Palette.popover)
            } else {
                shape.fill(.ultraThinMaterial)
                shape.fill(Palette.popover.opacity(0.88))
            }
        }
    }
}

/// How much of a panel shows while it grows out of a tile: its top `height` points, rounded by
/// `cornerRadius`, in the panel's own points.
struct PanelReveal: Equatable {
    var height: CGFloat
    var cornerRadius: CGFloat
}

extension EnvironmentValues {
    @Entry var panelReveal: PanelReveal?
}

/// A rounded rect cut to its top `height` points, or the whole rect with no height.
private struct RevealedRect: InsettableShape {
    var height: CGFloat?
    var cornerRadius: CGFloat
    var inset: CGFloat = 0

    nonisolated func path(in rect: CGRect) -> Path {
        let shown = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: min(height ?? rect.height, rect.height))
        return Path(roundedRect: shown.insetBy(dx: inset, dy: inset), cornerRadius: max(cornerRadius - inset, 0), style: .continuous)
    }

    nonisolated func inset(by amount: CGFloat) -> RevealedRect {
        var shape = self
        shape.inset += amount
        return shape
    }
}

/// Sort's shadows, its CSS blur halved for SwiftUI's radius. Spread has no SwiftUI equivalent, so
/// the drop's negative spread is folded into a slightly smaller radius.
private struct SurfaceShadow: ViewModifier {
    let depth: PanelSurface.Depth

    func body(content: Content) -> some View {
        switch depth {
        case .card:
            content
                .shadow(color: .black.opacity(0.28), radius: 1, y: 2)
                .shadow(color: .black.opacity(0.22), radius: 0.5, y: 1)
        case .panel:
            content
                .shadow(color: .black.opacity(0.2), radius: 5)
                .shadow(color: .black.opacity(0.3), radius: 4, y: 8)
                .shadow(color: .black.opacity(0.3), radius: 12, y: 20)
        }
    }
}

extension View {
    func panelSurface(_ depth: PanelSurface.Depth = .panel, cornerRadius: CGFloat = PanelSurface.cornerRadius, edge: Color = Palette.edge) -> some View {
        modifier(PanelSurface(cornerRadius: cornerRadius, depth: depth, edge: edge))
    }
}
