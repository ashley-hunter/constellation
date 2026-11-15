import SwiftUI

/// SF Pro for the UI and SF Mono for code. Host Grotesk and Fragment Mono are still bundled if we switch back.
extension Font {
    static func ui(_ size: CGFloat = 13, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func mono(_ size: CGFloat = 12, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}
