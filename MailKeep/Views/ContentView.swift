import SwiftUI
import AppKit

/// Fige la largeur de la colonne des comptes, par une contrainte Auto Layout posée sur la
/// colonne elle-même.
///
/// La colonne reste une colonne du split view : c'est d'elle que la fenêtre tire le
/// `sidebarTrackingSeparator` de sa barre d'outils, donc la position des icônes au-dessus
/// de la sidebar et le titre au-dessus de la colonne du milieu. Sortie du split, tout ce
/// décor part avec elle.
///
/// La contrainte est posée sur la vue de colonne, pas sur le `NSSplitViewItem` : les
/// épaisseurs de l'item meurent avec lui quand SwiftUI reconstruit ses colonnes, la
/// contrainte, elle, vit aussi longtemps que la colonne. Rien à reposer en continu, donc
/// rien qui lutte contre la passe de mise en page d'AppKit — et une contrainte requise ne
/// laisse aucun jeu au séparateur ni à une géométrie restaurée au lancement.
private struct ColumnWidthLock: NSViewRepresentable {
    let width: CGFloat

    private static let identifier = "MailKeepSidebarWidth"

    final class Coordinator {
        var observer: NSObjectProtocol?
        var apply: (() -> Void)?
        deinit { observer.map(NotificationCenter.default.removeObserver) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.apply = { [weak nsView] in
            guard let nsView else { return }
            Self.apply(width: width, from: nsView)
        }
        // Quand SwiftUI reconstruit ses colonnes — ce que fait chaque rafraîchissement de
        // l'historique en plein backup — la nouvelle colonne repart sans contrainte, et
        // `updateNSView` n'est pas rappelé puisque la largeur n'a pas changé. On ré-attache
        // donc après chaque passe de redimensionnement : différé pour ne rien écrire pendant
        // la passe d'AppKit, et sans effet quand la contrainte est déjà en place.
        if coordinator.observer == nil {
            coordinator.observer = NotificationCenter.default.addObserver(
                forName: NSSplitView.didResizeSubviewsNotification,
                object: nil, queue: .main
            ) { [weak coordinator] _ in
                DispatchQueue.main.async { coordinator?.apply?() }
            }
        }
        // Différé : à l'appel, la vue n'est pas encore dans la hiérarchie du split view.
        DispatchQueue.main.async { coordinator.apply?() }
    }

    private static func apply(width: CGFloat, from nsView: NSView) {
        var candidate: NSView? = nsView
        while let view = candidate, !(view.superview is NSSplitView) {
            candidate = view.superview
        }
        guard let column = candidate, let split = column.superview as? NSSplitView else { return }

        // `>=` et non `==` : la colonne peut être élargie au séparateur, jamais rétrécie
        // sous la largeur de son contenu — ni par un drag, ni par une géométrie restaurée.
        if let existing = column.constraints.first(where: { $0.identifier == identifier }) {
            if existing.constant != width { existing.constant = width }
        } else {
            let lock = column.widthAnchor.constraint(greaterThanOrEqualToConstant: width)
            lock.identifier = identifier
            lock.isActive = true
        }

        // Sans ça, la colonne reste repliable par le menu Présentation.
        if let controller = split.delegate as? NSSplitViewController,
           let index = split.arrangedSubviews.firstIndex(of: column),
           controller.splitViewItems.indices.contains(index) {
            controller.splitViewItems[index].canCollapse = false
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var backupEngine: BackupEngine
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    /// Largeur de la colonne des comptes : celle de son contenu, loader et icône compris.
    private var sidebarWidth: CGFloat { SidebarMetrics.width(for: appState.accounts) }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                // Largeur de départ ; ensuite c'est le verrou ci-dessous qui borne le
                // plancher, le séparateur reste libre vers la droite.
                .navigationSplitViewColumnWidth(min: sidebarWidth, ideal: sidebarWidth, max: 700)
                .background(ColumnWidthLock(width: sidebarWidth))
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
