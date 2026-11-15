import CoreGraphics

/// Sort's corner radii: surfaces (panels, cards, sheets), what sits inside them (popovers, banners),
/// controls (rows, chips, fields), and key caps.
enum Radius {
    static let surface: CGFloat = 20
    static let inner: CGFloat = 12
    static let control: CGFloat = 8
    static let key: CGFloat = 5
}
