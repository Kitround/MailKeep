import SwiftUI
import AppKit

/// Impose les bornes de la colonne latérale au `NSSplitViewItem` sous-jacent.
///
/// Les bornes SwiftUI (`navigationSplitViewColumnWidth`) ne sont appliquées qu'à la première
/// mise en page : fenêtre fermée puis rouverte, la colonne se comprimait sous son minimum
/// (textes tronqués), et un glissé la poussait au-delà de son maximum jusqu'à avaler la
/// fenêtre. AppKit, lui, respecte ces épaisseurs à tout moment.
private struct SidebarWidthBounds: NSViewRepresentable {
    let minimum: CGFloat
    let maximum: CGFloat

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Asynchrone : au moment de l'appel la vue n'est pas encore dans une fenêtre.
        DispatchQueue.main.async {
            guard let root = nsView.window?.contentViewController,
                  let split = Self.firstSplitViewController(in: root),
                  let sidebar = split.splitViewItems.first else { return }
            sidebar.canCollapse = false
            sidebar.minimumThickness = minimum
            sidebar.maximumThickness = maximum
        }
    }

    private static func firstSplitViewController(in controller: NSViewController) -> NSSplitViewController? {
        if let split = controller as? NSSplitViewController { return split }
        for child in controller.children {
            if let found = firstSplitViewController(in: child) { return found }
        }
        return nil
    }
}

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var backupEngine: BackupEngine
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    /// Marge d'élargissement autorisée au-delà de la largeur du contenu.
    private static let sidebarSlack: CGFloat = 100

    /// Largeur qui fait tenir le contenu sans troncature : c'est le minimum, et aussi
    /// la largeur d'ouverture. On ne peut donc élargir que vers la droite.
    private var sidebarWidth: CGFloat { SidebarMetrics.width(for: appState.accounts) }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(
                    min: sidebarWidth, ideal: sidebarWidth, max: sidebarWidth + Self.sidebarSlack
                )
                // Les mêmes bornes côté AppKit, seul niveau où elles tiennent vraiment.
                .background(SidebarWidthBounds(
                    minimum: sidebarWidth, maximum: sidebarWidth + Self.sidebarSlack
                ))
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
        // Empêche la sidebar d'être réduite via raccourci clavier ou menu Présentation
        .onChange(of: columnVisibility) { _, v in
            if v != .all { columnVisibility = .all }
        }
    }
}
