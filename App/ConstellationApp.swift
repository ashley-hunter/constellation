import ConstellationCore
import SwiftUI

@main
struct ConstellationApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // No window scenes: SwiftUI opens a window scene by itself at launch and on activation, which
        // would cover the desktop and take the keyboard. Settings is an AppKit window (SettingsWindow).
        MenuBarExtra {
            AttentionMenu(model: appDelegate.model)
        } label: {
            AttentionMenuLabel(model: appDelegate.model)
        }
        .commands {
            AppCommands(model: appDelegate.model)
            UpdateCommands()
        }
    }
}

/// The menu bar. Every item is a registered action, so it runs exactly what its key and palette row run.
struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            ActionButton(.settings).environment(model)
        }
        CommandGroup(replacing: .newItem) {
            Group {
                ActionButton(.sessionNew, title: "New Session…")
                ActionButton(.terminalNew)
                Divider()
                ActionButton(.projectNew, title: "New Project…")
                ActionButton(.projectAdd, title: "Add Project…")
                Divider()
                ActionButton(.palette, title: "Command Palette…")
            }
            .environment(model)
        }
        // In place of the window Close, so ⌘W closes the focused tile. Settings closes itself on ⌘W.
        CommandGroup(replacing: .saveItem) {
            ActionButton(.tileClose).environment(model)
        }
        CommandMenu("Session") {
            Group {
                ActionButton(.tileOpen, title: "Open")
                ActionButton(.askOpen)
                Divider()
                ActionButton(.gitCommit)
                ActionButton(.gitPush)
                ActionButton(.gitPullRequest)
                ActionButton(.gitMerge)
                Divider()
                ActionButton(.sessionRename)
                ActionButton(.sessionOpenInEditor)
                ActionButton(.sessionTerminal)
                Divider()
                ActionButton(.sessionFork)
                ActionButton(.sessionRewind)
                Divider()
                ActionButton(.sessionInterrupt)
                ActionButton(.sessionStop)
                ActionButton(.sessionRetry)
                ActionButton(.sessionResume)
                ActionButton(.sessionSettle)
                ActionButton(.sessionArchive)
                Divider()
                ActionButton(.triage)
                ActionButton(.focusNextBlocked)
            }
            .environment(model)
        }
        CommandGroup(replacing: .sidebar) {
            ActionButton(.sidebarToggle).environment(model)
        }
        CommandMenu("Arrange") {
            Group {
                ActionButton(.cleanup, title: "Clean Up Merged Work…")
            }
            .environment(model)
        }
        #if DEBUG
        // Debug builds only: any onboarding step on demand, for working on it.
        CommandMenu("Debug") {
            Menu("Onboarding") {
                ForEach(OnboardingStep.allCases, id: \.self) { step in
                    Button("\(step)".capitalized) { model.beginOnboarding(at: step) }
                }
            }
        }
        #endif
    }
}
