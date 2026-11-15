import AppKit
import SwiftUI

/// Hover picks a row only when the pointer has moved since the last hover or key press, not when
/// rows reflow under a pointer standing still.
@MainActor
enum PointerHover {
    private static var last = NSEvent.mouseLocation

    static func moved() -> Bool {
        let now = NSEvent.mouseLocation
        defer { last = now }
        return now != last
    }

    /// After a key press: the pointer stays where it is, so the next reflow mustn't move the selection.
    static func settle() {
        last = NSEvent.mouseLocation
    }
}

extension View {
    /// Puts the arrow back over controls next to a text field, which leaves the I-beam behind
    /// when the pointer moves off it onto SwiftUI views that never set a cursor.
    func arrowCursor() -> some View {
        contentShape(.rect).onContinuousHover { phase in
            if case .active = phase { NSCursor.arrow.set() }
        }
    }
}
