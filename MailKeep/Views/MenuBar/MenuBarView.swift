import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var backupEngine: BackupEngine
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if appState.isRunningBackup {
                ForEach(Array(appState.activeProgress.values)) { progress in
                    HStack {
                        ProgressView().controlSize(.mini)
                        Text(progress.folderName)
                            .lineLimit(1)
                        Spacer()
                        Text("\(progress.current)/\(progress.total)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .font(.caption)
                }
                Divider()
            } else {
                lastBackupLabel
                Divider()
            }

            Button("Tout sauvegarder") {
                Task { await backupEngine.backupAll() }
            }
            .disabled(appState.isRunningBackup || appState.accounts.isEmpty || appState.backupBaseURL == nil)

            Button("Ouvrir MailKeep") {
                // openWindow recrée la fenêtre si elle a été fermée —
                // NSApp.windows.first ne marchait plus dans ce cas.
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }

            Divider()

            Button("Quitter") {
                NSApp.terminate(nil)
            }
        }
        .padding(4)
    }

    private var lastBackupLabel: some View {
        Group {
            if let last = appState.backupRuns.last {
                (Text("Dernier : ") + Text(last.startedAt, style: .relative))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Aucun backup effectué")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
