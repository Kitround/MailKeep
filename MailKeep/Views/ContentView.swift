import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var backupEngine: BackupEngine
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        // La colonne des comptes est hors du NavigationSplitView, volontairement.
        // Tant qu'elle en faisait partie, SwiftUI lui collait une poignée de
        // redimensionnement impossible à retirer, et aucune contrainte de largeur —
        // `navigationSplitViewColumnWidth`, `frame`, ou verrou sur le NSSplitViewItem —
        // n'a tenu : la colonne se comprimait à la réouverture de la fenêtre et débordait
        // quand on tirait le séparateur. Hors du split, il n'y a plus de séparateur du
        // tout : largeur mesurée sur le contenu, colonne toujours visible.
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: SidebarMetrics.width(for: appState.accounts))
            Divider()
            splitView
        }
        .frame(minWidth: 900, minHeight: 600)
        .navigationTitle("MailKeep")
        // Reset selected email when folder changes
        .onChange(of: appState.selectedFolderID) { _, _ in
            appState.selectedEmail = nil
        }
    }

    private var splitView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // Center panel: email list if mbox available, else backup history
            if let account = appState.selectedAccount,
               let folder = appState.selectedFolder,
               !appState.selectedMboxURLs.isEmpty {
                EmailListView(account: account, folder: folder,
                              mboxURLs: appState.selectedMboxURLs,
                              indexURL: appState.selectedIndexURL)
                    .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 480)
            } else {
                BackupHistoryView()
                    .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 400)
            }
        } detail: {
            // Detail: email reader if selected, else folder/progress view
            if let email = appState.selectedEmail {
                EmailDetailView(email: email)
            } else {
                DetailView()
            }
        }
        .toolbar(removing: .sidebarToggle)
        // Empêche la colonne du milieu d'être réduite via raccourci clavier ou menu Présentation
        .onChange(of: columnVisibility) { _, v in
            if v != .all { columnVisibility = .all }
        }
    }
}
