import AppKit
import SwiftUI

/// A working card's edge: a soft light travelling slowly round it. Core Animation turns it, so it
/// costs the app nothing per frame. Under Reduce Motion it's a still edge in the same colour.
struct TravellingEdge: View {
    var cornerRadius: CGFloat = PanelSurface.cornerRadius
    var color: Color = Palette.working
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(color.opacity(0.6), lineWidth: 1)
            } else {
                EdgeLight(cornerRadius: cornerRadius, color: NSColor(color))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct EdgeLight: NSViewRepresentable {
    let cornerRadius: CGFloat
    let color: NSColor

    func makeNSView(context: Context) -> EdgeLightView {
        EdgeLightView(cornerRadius: cornerRadius, color: color)
    }

    func updateNSView(_ view: EdgeLightView, context: Context) {}
}

/// A conic gradient with one bright arc, turning behind a mask that shows only a 1.5 pt border.
private final class EdgeLightView: NSView {
    private let holder = CALayer()
    private let gradient = CAGradientLayer()
    private let border = CAShapeLayer()
    private let cornerRadius: CGFloat

    init(cornerRadius: CGFloat, color: NSColor) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        gradient.type = .conic
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.colors = [color.withAlphaComponent(0).cgColor, color.withAlphaComponent(0).cgColor, color.withAlphaComponent(0.95).cgColor, color.withAlphaComponent(0).cgColor]
        gradient.locations = [0, 0.62, 0.84, 1]
        border.fillColor = nil
        border.strokeColor = NSColor.black.cgColor
        border.lineWidth = 1.5
        holder.mask = border
        holder.addSublayer(gradient)
        layer?.addSublayer(holder)
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi
        spin.duration = 3.6
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        gradient.add(spin, forKey: "travel")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        holder.frame = bounds
        border.frame = bounds
        border.path = CGPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        let side = hypot(bounds.width, bounds.height)
        gradient.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        gradient.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }
}
