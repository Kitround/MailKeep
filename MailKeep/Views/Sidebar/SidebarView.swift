import SwiftUI
import AppKit

/// Une entrée de menu décrite une seule fois, rendue soit par SwiftUI (clic droit)
/// soit par AppKit (bouton « … » de la sidebar).
struct MenuAction {
    let title: String
    let enabled: Bool
    let isSeparator: Bool
    let run: () -> Void

    init(_ title: String, enabled: Bool = true, run: @escaping () -> Void) {
        self.title = title
        self.enabled = enabled
        self.isSeparator = false
        self.run = run
    }

    static let separator = MenuAction(separator: ())

    private init(separator _: ()) {
        title = ""
        enabled = false
        isSeparator = true
        run = {}
    }
}

extension NSMenu {
    /// Ouvre un vrai menu macOS au pointeur. Préféré à un `Menu` SwiftUI : celui-ci
    /// impose son propre chrome, qui décale son glyphe par rapport aux autres icônes
    /// de la sidebar et le noircit en dark mode.
    static func popUpAtPointer(items: [MenuAction]) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            menu.addItem(item.isSeparator ? .separator() : ClosureMenuItem(item))
        }
        guard let event = NSApp.currentEvent, let view = event.window?.contentView else { return }
        menu.popUp(positioning: nil, at: view.convert(event.locationInWindow, from: nil), in: view)
    }
}

/// `NSMenuItem` qui appelle une closure — AppKit ne sait cibler que des sélecteurs.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ action: MenuAction) {
        handler = action.run
        super.init(title: action.title, action: #selector(fire), keyEquivalent: "")
        target = self
        isEnabled = action.enabled
    }

    required init(coder: NSCoder) { fatalError("init(coder:) non supporté") }

    @objc private func fire() { handler() }
}

/// Largeur de la colonne latérale, mesurée sur ce qu'elle contient.
///
/// Une `List` n'a pas de largeur intrinsèque : elle remplit ce qu'on lui donne. On mesure
/// donc les textes réellement affichés — libellés de comptes, adresses, noms de dossiers —
/// et on ajoute le décor de chaque ligne (chevron, retrait, icône, bouton d'action, marge).
enum SidebarMetrics {
    /// Décor d'une ligne de compte : chevron + marge, puis roue crantée + marge droite.
    private static let accountChrome: CGFloat = 22 + 36
    /// Décor d'une ligne de dossier : retrait + icône + espacement, puis menu + marge droite.
    private static let folderChrome: CGFloat = 41 + 16 + 8 + 36
    private static let historyChrome: CGFloat = 24 + 36
    /// Bornes de sécurité : un libellé vide ne doit pas produire une colonne ridicule,
    /// une adresse à rallonge ne doit pas manger la fenêtre.
    private static let bounds: ClosedRange<CGFloat> = 240...420

    static func width(for accounts: [IMAPAccount]) -> CGFloat {
        var widest = textWidth("Historique", style: .body) + historyChrome
        for account in accounts {
            let label = account.label.isEmpty ? account.host : account.label
            widest = max(widest, textWidth(label, style: .headline) + accountChrome)
            widest = max(widest, textWidth(account.username, style: .caption1) + 22 + 36)
            for folder in account.folders {
                widest = max(widest, textWidth(folder.displayName, style: .body) + folderChrome)
            }
        }
        return min(max(widest.rounded(.up), bounds.lowerBound), bounds.upperBound)
    }

    private static func textWidth(_ string: String, style: NSFont.TextStyle) -> CGFloat {
        let font = NSFont.preferredFont(forTextStyle: style)
        return (string as NSString).size(withAttributes: [.font: font]).width
    }
}

/// Métriques partagées des icônes d'action de la sidebar (roue crantée des
/// comptes, menu « … » des dossiers), pour que les deux colonnes s'alignent.
enum SidebarIcon {
    /// 16 = taille de `.body` (13) + 3, calée à l'œil.
    static let font = Font.system(size: 16)
    /// Marge droite du glyphe, identique pour les deux icônes.
    static let trailing: CGFloat = 8
    /// Marge cliquable autour du glyphe : 16 + 2×6 = zone de 28.
    static let pad: CGFloat = 6
    /// Zone cliquable, et surtout boîte carrée commune : `gearshape` et
    /// `ellipsis.circle` n'ont pas la même largeur intrinsèque, sans cadre imposé
    /// leurs centres ne tombent pas au même endroit.
    static var hit: CGFloat { 16 + 2 * pad }
}

/// Glyphe d'action de la sidebar : taille, couleurs et zone cliquable élargie par
/// padding — pas par `frame`, qui pousse un `Menu` borderless à dessiner son bezel.
/// Partagé pour que roue crantée et menu « … » soient identiques. Survol = couleur
/// seule, pas de fond.
struct SidebarIconLabel: View {
    let systemName: String
    let isHovered: Bool

    var body: some View {
        Image(systemName: systemName)
            .font(SidebarIcon.font)
            .foregroundStyle(isHovered ? .primary : .secondary)
            .frame(width: SidebarIcon.hit, height: SidebarIcon.hit)
            .contentShape(Rectangle())
    }
}

struct SidebarView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var backupEngine: BackupEngine
    @State private var showAddAccount = false
    @State private var editingAccount: IMAPAccount? = nil
    @State private var expandedAccounts: Set<UUID> = []
    @State private var historiqueHovered = false

    private var isHistoriqueSelected: Bool {
        appState.selectedAccountID == nil
    }

    var body: some View {
        sidebarList
            .listStyle(.sidebar)
            .onAppear { expandedAccounts = Set(appState.accounts.map { $0.id }) }
            .onChange(of: appState.accounts.map(\.id)) { old, new in
                let added = Set(new).subtracting(Set(old))
                for id in added { expandedAccounts.insert(id) }
            }
            .toolbar { sidebarToolbar }
            .sheet(isPresented: $showAddAccount) {
                AccountSettingsView(account: IMAPAccount.new(), isNew: true)
                    .environmentObject(appState)
            }
            .sheet(item: $editingAccount) { account in
                AccountSettingsView(account: account, isNew: false)
                    .environmentObject(appState)
            }
            .overlay { emptyOverlay }
    }

    // MARK: - List

    private var sidebarList: some View {
        List {
            historiqueRow
            Section {
                ForEach(appState.accounts) { account in
                    AccountSectionView(
                        account: account,
                        isExpanded: expandedBinding(for: account),
                        onEdit: { editingAccount = account }
                    )
                }
            } header: {
                Text("Comptes")
            }
        }
    }

    // MARK: - Historique row

    private var historiqueRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock").frame(width: 16)
            Text("Historique")
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .listRowInsets(EdgeInsets(top: 4, leading: -3, bottom: 4, trailing: 8))
        .listRowBackground(historiqueBackground)
        .onHover { historiqueHovered = $0 }
        .onTapGesture {
            appState.selectedAccountID = nil
            appState.selectedFolderID = nil
            appState.selectedEmail = nil
        }
    }

    private var historiqueBackground: some View {
        Rectangle().fill(
            isHistoriqueSelected ? Color.accentColor.opacity(0.2)
            : historiqueHovered  ? Color.primary.opacity(0.06)
            : Color.clear
        )
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var sidebarToolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                Task { await backupEngine.backupAll() }
            } label: {
                Label("Tout sauvegarder", systemImage: "arrow.down.circle")
            }
            .disabled(appState.isRunningBackup || appState.accounts.isEmpty)
            .help("Lancer le backup de tous les comptes")

            if appState.backupBaseURL == nil {
                Button { appState.chooseBackupDirectory() } label: {
                    Label("Dossier backup", systemImage: "folder.badge.plus")
                }
                .help("Choisir le dossier de sauvegarde")
            }

            Button { showAddAccount = true } label: {
                Label("Ajouter un compte", systemImage: "plus")
            }
            .help("Ajouter un compte IMAP")
        }
    }

    // MARK: - Empty overlay

    @ViewBuilder
    private var emptyOverlay: some View {
        if appState.accounts.isEmpty {
            ContentUnavailableView(
                "Aucun compte",
                systemImage: "envelope",
                description: Text("Cliquez sur + pour ajouter un compte IMAP.")
            )
        }
    }

    // MARK: - Helpers

    private func expandedBinding(for account: IMAPAccount) -> Binding<Bool> {
        Binding(
            get: { expandedAccounts.contains(account.id) },
            set: { val in
                if val { expandedAccounts.insert(account.id) }
                else   { expandedAccounts.remove(account.id) }
            }
        )
    }
}

// MARK: - Sous-vue par compte

private struct AccountSectionView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var backupEngine: BackupEngine
    let account: IMAPAccount
    @Binding var isExpanded: Bool
    let onEdit: () -> Void

    var body: some View {
        AccountRowView(account: account, isExpanded: $isExpanded, onEdit: onEdit)
        if isExpanded {
            ForEach(account.folders) { folder in
                FolderRowView(account: account, folder: folder)
                    .id(folder.id)
                    // trailing 0 : le menu « … » porte lui-même son padding de 8,
                    // comme la roue crantée du compte, pour que les deux s'alignent.
                    .listRowInsets(EdgeInsets(top: 3, leading: 41, bottom: 3, trailing: 0))
            }
        }
    }
}

// MARK: - Preview

private extension IMAPAccount {
    static var mockWork: IMAPAccount {
        var a = IMAPAccount(label: "Work", host: "imap.example.com", username: "alex.morgan@example.com")
        a.folders = [MailFolder(name: "INBOX"), MailFolder(name: "Sent")]
        a.schedule = { var s = BackupSchedule(); s.isEnabled = true; s.lastBackupDate = Date().addingTimeInterval(-3600); return s }()
        return a
    }
    static var mockPersonal: IMAPAccount {
        var a = IMAPAccount(label: "Personal", host: "mail.example.org", username: "alex@example.org")
        a.folders = [MailFolder(name: "Archives"), MailFolder(name: "INBOX"), MailFolder(name: "Sent")]
        return a
    }
}

#Preview {
    let state = AppState()
    state.accounts = [.mockWork, .mockPersonal]
    let engine = BackupEngine()
    engine.appState = state
    return SidebarView()
        .environmentObject(state)
        .environmentObject(engine)
        .frame(width: 260)
}
