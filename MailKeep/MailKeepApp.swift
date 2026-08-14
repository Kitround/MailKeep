import SwiftUI

@main
struct MailKeepApp: App {
    // `@State` and not `@StateObject`, deliberately. `@StateObject` subscribes the App
    // body to `objectWillChange`, so the **whole** scene — including `.commands`, i.e. the
    // main menu — was rebuilt on every progress write. With a menu open AppKit runs a modal
    // tracking loop where any item change calls `menuNeedsUpdate`, which renders the view,
    // which changes the items again… until the stack overflows. `@State` keeps the objects
    // alive without subscribing; the views that need them subscribe individually through
    // `@EnvironmentObject`.
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

        // The label is deliberately fixed: deriving it from state would subscribe the App
        // body to `objectWillChange`, which is exactly what the `@State` above exists to
        // avoid — the whole scene, main menu included, would be rebuilt on every progress
        // write. State lives in the panel, which observes it on its own.
        MenuBarExtra("MailKeep", systemImage: "tray.and.arrow.down") {
            MenuBarView()
                .environmentObject(appState)
                .environmentObject(backupEngine)
        }
        // `.window` rather than the default `.menu` style: that one builds a real
        // `NSMenu`, whose synchronous, re-entrant updates recursed until the stack blew as
        // soon as a backup started writing progress.
        .menuBarExtraStyle(.window)

        Settings {
            AppSettingsView()
                .environmentObject(appState)
        }
    }
}
