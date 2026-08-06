import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var backupEngine: BackupEngine
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                // Largeur fixe, assumée. La variante redimensionnable
                // (`navigationSplitViewColumnWidth(min:ideal:max:)`) n'a tenu ni sa borne
                // basse ni sa borne haute : à la réouverture de la fenêtre la colonne se
                // comprimait sous le minimum (noms tronqués, icônes à la ligne), et tirée
                // à la main elle dépassait le maximum jusqu'à avaler la fenêtre — le
                // `frame` du contenu ne borne pas le séparateur. Une largeur unique ne
                // peut casser dans aucun des deux sens.
                .frame(width: 290)
                .navigationSplitViewColumnWidth(290)
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
        // Empêche la sidebar d'être réduite via raccourci clavier ou menu View
        .onChange(of: columnVisibility) { _, v in
            if v != .all { columnVisibility = .all }
        }
    }
}
