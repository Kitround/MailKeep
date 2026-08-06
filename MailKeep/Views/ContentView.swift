import SwiftUI
import AppKit

/// Impose les bornes de largeur de la colonne latérale au `NSSplitViewItem` qui la porte.
///
/// Pourquoi ne pas se contenter de `navigationSplitViewColumnWidth` : ses bornes ne sont
/// appliquées qu'à la première mise en page. Fenêtre fermée puis rouverte, la colonne
/// repartait sous son minimum ; tirée à la main, elle dépassait son maximum.
///
/// Deux pièges, tous deux rencontrés :
/// - viser `splitViewItems.first` du contrôleur racine ne désigne pas notre colonne dans la
///   hiérarchie que SwiftUI construit — la recherche échouait et aucune borne n'était posée.
///   On remonte donc depuis notre propre vue jusqu'à l'enfant direct du `NSSplitView`.
/// - toute écriture qui salit la mise en page relance `updateNSView`, qui réécrit, etc.
///   D'où l'écriture strictement idempotente : on ne touche que ce qui diffère.
private struct SidebarWidthBounds: NSViewRepresentable {
    let minimum: CGFloat
    let maximum: CGFloat

    /// Retient l'abonnement aux remaniements du split : SwiftUI remplace les
    /// `NSSplitViewItem` quand la colonne du milieu change de contenu — ce qui arrive en
    /// plein backup, quand la liste d'emails remplace l'historique. Les bornes posées sur
    /// l'ancien item disparaissent avec lui, et `updateNSView` n'est pas rappelé puisque
    /// nos valeurs n'ont pas bougé : la colonne redevenait librement redimensionnable et
    /// repliable. On les repose donc à chaque redisposition.
    final class Coordinator {
        var observer: NSObjectProtocol?
        var reapply: (() -> Void)?

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.reapply = { [weak nsView] in
            guard let nsView else { return }
            apply(from: nsView)
        }
        if coordinator.observer == nil {
            coordinator.observer = NotificationCenter.default.addObserver(
                forName: NSSplitView.didResizeSubviewsNotification,
                object: nil, queue: .main
            ) { [weak coordinator] _ in
                coordinator?.reapply?()
            }
        }
        // Asynchrone : au moment de l'appel la vue n'est pas encore dans sa fenêtre.
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

        let item = controller.splitViewItems[index]
        if item.minimumThickness != minimum { item.minimumThickness = minimum }
        if item.maximumThickness != maximum { item.maximumThickness = maximum }
        if item.canCollapse { item.canCollapse = false }
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
