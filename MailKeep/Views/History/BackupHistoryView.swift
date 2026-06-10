import SwiftUI

struct BackupHistoryView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var backupEngine: BackupEngine

    var runs: [BackupRun] {
        if let _ = appState.selectedFolderID,
           let folder = appState.selectedFolder {
            return appState.runsFor(accountID: appState.selectedAccountID ?? UUID(), folderName: folder.name)
        } else if let accountID = appState.selectedAccountID {
            return appState.runsFor(accountID: accountID)
        }
        return appState.backupRuns.sorted { $0.startedAt > $1.startedAt }
    }

    var title: String {
        if let folder = appState.selectedFolder { return folder.displayName }
        if let account = appState.selectedAccount { return account.label.isEmpty ? account.host : account.label }
        return "Historique"
    }

    var body: some View {
        Group {
            if runs.isEmpty {
                ContentUnavailableView(
                    "Aucun backup",
                    systemImage: "clock",
                    description: Text("Les backups apparaîtront ici.")
                )
            } else {
                ScrollViewReader { proxy in
                    List(runs) { run in
                        BackupRunRowView(run: run)
                            .environmentObject(appState)
                            .environmentObject(backupEngine)
                            .id(run.id)
                    }
                    .listStyle(.plain)
                    .onAppear {
                        if let first = runs.first {
                            proxy.scrollTo(first.id, anchor: .top)
                        }
                    }
                    .onChange(of: runs.first?.id) {
                        if let first = runs.first {
                            proxy.scrollTo(first.id, anchor: .top)
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
    }
}
