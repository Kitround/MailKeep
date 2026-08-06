import SwiftUI
import AppKit

/// Épingle la colonne latérale à une largeur fixe, côté AppKit.
///
/// SwiftUI laisse le séparateur déplaçable même avec une largeur de colonne fixe, et ni
/// `navigationSplitViewColumnWidth` ni un `frame` sur le contenu ne le bornent réellement :
/// la colonne se comprimait à la réouverture de la fenêtre et débordait quand on tirait le
/// séparateur. Seul le `NSSplitViewItem` sous-jacent tranche — épaisseurs minimale et
/// maximale égales, et pas de repli possible.
private struct SidebarWidthLock: NSViewRepresentable {
    let width: CGFloat

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Asynchrone : au moment de l'appel la vue n'est pas encore dans une fenêtre.
        DispatchQueue.main.async {
            guard let root = nsView.window?.contentViewController,
                  let split = Self.firstSplitViewController(in: root),
                  let sidebar = split.splitViewItems.first else { return }
            sidebar.canCollapse = false
            sidebar.minimumThickness = width
            sidebar.maximumThickness = width
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

    private static let sidebarWidth: CGFloat = 290

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .frame(width: Self.sidebarWidth)
                .navigationSplitViewColumnWidth(Self.sidebarWidth)
                // Verrou AppKit : sans lui le séparateur reste déplaçable.
                .background(SidebarWidthLock(width: Self.sidebarWidth))
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
