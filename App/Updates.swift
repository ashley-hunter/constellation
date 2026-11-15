import Sparkle
import SwiftUI

/// Sparkle, checking the newest GitHub release's appcast (SUFeedURL in Info.plist). Release builds
/// only: a debug build would otherwise offer to replace itself with the published app.
@MainActor
enum Updates {
    #if DEBUG
    static let isEnabled = false
    #else
    static let isEnabled = true
    #endif

    static let controller = SPUStandardUpdaterController(
        startingUpdater: isEnabled, updaterDelegate: nil, userDriverDelegate: nil)
}

/// "Check for Updates…" under About in the app menu.
struct UpdateCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            if Updates.isEnabled {
                Button("Check for Updates…") { Updates.controller.checkForUpdates(nil) }
            }
        }
    }
}
