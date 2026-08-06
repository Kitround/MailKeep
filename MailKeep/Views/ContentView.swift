import SwiftUI
import AppKit

/// Coupe l'enregistrement automatique des positions de séparateur du split view.
///
/// AppKit sauvegarde ces positions dans les préférences (`NSSplitView Subview Frames …`) et
/// les restaure à l'ouverture d'une fenêtre, **après** la mise en page SwiftUI : la largeur
/// demandée était donc systématiquement écrasée par la dernière position enregistrée, d'où
/// la colonne minuscule à chaque réouverture, quelle que soit la contrainte posée dans le
/// code. Sans nom d'enregistrement, il n'y a plus rien à restaurer.
///
/// Assignation unique, sans effet sur la géométrie : contrairement aux bornes reposées en
/// continu, elle ne relance pas la mise en page et ne lutte contre aucun geste.
private struct SidebarWidthLock: NSViewRepresentable {
    let width: CGFloat

    final class Coordinator {
        var observer: NSObjectProtocol?
        var reapply: (() -> Void)?
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.reapply = { [weak nsView] in
            guard let nsView else { return }
            apply(from: nsView)
        }
        // SwiftUI reconstruit ses colonnes quand la colonne du milieu change de contenu —
        // en plein backup, quand la liste d'emails remplace l'historique. Les épaisseurs
        // posées sur l'ancien `NSSplitViewItem` disparaissent avec lui : on les repose.
        // Les deux bornes étant égales, il n'existe aucune plage de glissement, donc rien
        // à quoi ce code puisse s'opposer pendant que l'utilisateur tire le séparateur.
        if coordinator.observer == nil {
            coordinator.observer = NotificationCenter.default.addObserver(
                forName: NSSplitView.didResizeSubviewsNotification, object: nil, queue: .main
            ) { [weak coordinator] _ in
                coordinator?.reapply?()
            }
        }
        DispatchQueue.main.async { coordinator.reapply?() }
    }

    private func apply(from nsView: NSView) {
        var candidate: NSView? = nsView
        while let view = candidate, !(view.superview is NSSplitView) {
            candidate = view.superview
        }
        guard let column = candidate,
              let splitView = column.superview as? NSSplitView,
              let controller = splitView.delegate as? NSSplitViewController,
              let index = splitView.arrangedSubviews.firstIndex(of: column),
              controller.splitViewItems.indices.contains(index) else { return }

        // Épaisseurs identiques : la colonne ne peut ni être tirée, ni être écrasée par une
        // géométrie restaurée. Écritures idempotentes, pour ne pas relancer la mise en page.
        let item = controller.splitViewItems[index]
        if item.minimumThickness != width { item.minimumThickness = width }
        if item.maximumThickness != width { item.maximumThickness = width }
        if item.canCollapse { item.canCollapse = false }
        splitView.autosaveName = nil
        splitView.window?.isRestorable = false
    }
}

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
                // Seul mécanisme qui impose réellement la largeur : mesuré, la colonne
                // faisait 272 pt de contenu pour une colonne rendue bien plus étroite.
                .background(SidebarWidthLock(width: sidebarWidth))
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
