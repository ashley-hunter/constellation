import AppKit
import Observation

/// Which window level the desktop ended up at, and the wallpaper behind it.
@Observable
@MainActor
final class DesktopAppearance {
    enum Level: String {
        /// Just above the Finder's desktop icons, below every app window.
        case desktop
        /// The documented fallback when the desktop level can't take keys.
        case normal
    }

    var level: Level = .desktop
    var wallpaper = Wallpaper()
    /// One of the app's own pictures in place of your wallpaper, which it then draws itself.
    var background: Background?
    /// The app is frontmost. Drift and breathing hold still while it isn't, so the desktop costs
    /// nothing behind other apps.
    var isActive = true

    /// At normal level other apps' windows would show through, so draw the wallpaper instead; and
    /// always for one of the app's own pictures, which the real desktop doesn't have.
    var drawsWallpaper: Bool { level == .normal || background != nil }
}
