import SwiftUI

@main
struct MailKeepApp: App {
    // `@State` et non `@StateObject` : volontaire. `@StateObject` abonne le corps de
    // l'App à `objectWillChange`, donc **toute** la scène — dont `.commands`, c'est-à-dire
    // la barre de menus — était reconstruite à chaque écriture de progression. Menu ouvert,
    // AppKit tourne en boucle de suivi modale : chaque changement d'items appelle
    // `menuNeedsUpdate`, qui rend la vue, qui change encore les items… jusqu'au
    // débordement de pile. `@State` garde les objets en vie sans s'y abonner ; les vues
    // qui en ont besoin s'abonnent individuellement via `@EnvironmentObject`.
    @State private var appState = AppState()
    @State private var backupEngine = BackupEngine()
    @State private var scheduler = SchedulerService()

    var body: some Scene {
        WindowGroup("MailKeep", id: "main") {
            ContentView()
                .environmentObject(appState)
                .environmentObject(backupEngine)
                .onAppear {
                    backupEngine.appState = appState
                    #if DEBUG
                    if DemoSeeder.isActive {
                        DemoSeeder.seed(into: appState)
                        return
                    }
                    #endif
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
