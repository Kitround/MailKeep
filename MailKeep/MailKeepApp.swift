import SwiftUI

@main
struct MailKeepApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var backupEngine = BackupEngine()
    @StateObject private var scheduler = SchedulerService()

    var body: some Scene {
        WindowGroup("MailKeep") {
            ContentView()
                .environmentObject(appState)
                .environmentObject(backupEngine)
                .onAppear {
                    backupEngine.appState = appState
                    scheduler.start(appState: appState, engine: backupEngine)
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1480, height: 860)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Tout sauvegarder") {
                    Task { await backupEngine.backupAll() }
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra("MailKeep", systemImage: "tray.and.arrow.down") {
            MenuBarView()
                .environmentObject(appState)
                .environmentObject(backupEngine)
        }

        Settings {
            AppSettingsView()
                .environmentObject(appState)
        }
    }
}
