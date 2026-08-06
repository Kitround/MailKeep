import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var backupEngine: BackupEngine
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    /// Largeur de la colonne des comptes : celle de son contenu, marge comprise.
    private var sidebarWidth: CGFloat { SidebarMetrics.width(for: appState.accounts) }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // Largeur fixe, en une seule valeur : la colonne n'est pas redimensionnable.
            // Les variantes bornées (`min:ideal:max:`) n'ont jamais tenu — les bornes
            // SwiftUI ne valent qu'à la première mise en page, et celles posées sur le
            // `NSSplitViewItem` disparaissaient dès que SwiftUI reconstruisait ses colonnes,
            // ce qui arrive en plein backup quand la liste d'emails remplace l'historique.
            // Les reposer en continu revenait à lutter contre le glissé : d'où les sauts.
            // Ici il n'y a rien à borner ni à reposer.
            SidebarView()
                .navigationSplitViewColumnWidth(sidebarWidth)
                .toolbar(removing: .sidebarToggle)
        } content: {
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
        .navigationTitle("MailKeep")
        .frame(minWidth: 900, minHeight: 600)
        // Reset selected email when folder changes
        .onChange(of: appState.selectedFolderID) { _, _ in
            appState.selectedEmail = nil
        }
        // Empêche une colonne d'être réduite via raccourci clavier ou menu Présentation
        .onChange(of: columnVisibility) { _, v in
            if v != .all { columnVisibility = .all }
        }
    }
}
