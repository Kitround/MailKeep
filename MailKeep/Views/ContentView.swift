import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var backupEngine: BackupEngine
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    /// Largeur de la colonne des comptes : celle de son contenu, marge comprise.
    private var sidebarWidth: CGFloat { SidebarMetrics.width(for: appState.accounts) }

    var body: some View {
        // La colonne des comptes n'est pas une colonne du NavigationSplitView, et c'est
        // délibéré : tant qu'elle en faisait partie, elle portait un séparateur déplaçable.
        // Aucune contrainte n'a tenu — les bornes SwiftUI ne valent qu'à la première mise en
        // page, celles posées sur le `NSSplitViewItem` disparaissent quand SwiftUI
        // reconstruit ses colonnes (ce qui arrive à chaque rafraîchissement de l'historique
        // en cours de sauvegarde), et les reposer pendant la passe de mise en page d'AppKit
        // faisait s'effondrer la colonne. Sans séparateur, il n'y a plus rien à redimensionner.
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: sidebarWidth)
            Divider()
            splitColumns
        }
        .frame(minWidth: 900, minHeight: 600)
        .navigationTitle("MailKeep")
        // Reset selected email when folder changes
        .onChange(of: appState.selectedFolderID) { _, _ in
            appState.selectedEmail = nil
        }
    }

    /// Liste (emails ou historique) et détail : elles, restent redimensionnables entre elles.
    private var splitColumns: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
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
