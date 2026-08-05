import SwiftUI

struct FolderRowView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var backupEngine: BackupEngine
    let account: IMAPAccount
    let folder: MailFolder

    var isSelected: Bool {
        appState.selectedFolderID == folder.id && appState.selectedAccountID == account.id
    }

    var isRunning: Bool {
        appState.activeProgress.values.contains {
            $0.accountID == account.id && $0.folderName == folder.name
        }
    }

    @State private var isHovered = false
    @State private var iconHovered = false
    @State private var showRestore = false
    @State private var showDeleteConfirm = false

    var body: some View {
        HStack(spacing: 4) {
            HStack(alignment: .center) {
                Image(systemName: iconName)
                    .frame(width: 16)
                    .foregroundStyle(folder.isEnabled ? .primary : .tertiary)
                Text(folder.displayName)
                    .foregroundStyle(folder.isEnabled ? .primary : .secondary)
                Spacer()
                if isRunning {
                    ProgressView().controlSize(.mini)
                } else if !folder.isEnabled {
                    Image(systemName: "pause.circle")
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { select() }

            // Actions du dossier — mêmes entrées que la page de détail,
            // accessibles même quand un email est ouvert.
            // Bouton strictement identique à la roue crantée du compte (même label,
            // même padding) : alignement et couleurs par construction. Un Menu SwiftUI
            // ne convenait pas — son chrome décale le glyphe et le noircit en dark mode.
            Button {
                NSMenu.popUpAtPointer(items: actionItems)
            } label: {
                SidebarIconLabel(systemName: "ellipsis.circle", isHovered: iconHovered)
            }
            .buttonStyle(.plain)
            .onHover { iconHovered = $0 }
            .opacity(isHovered || iconHovered ? 1 : 0.5)
            .padding(.trailing, SidebarIcon.trailing - SidebarIcon.pad)
            .help("Actions du dossier")
        }
        .listRowBackground(
            Rectangle().fill(
                isSelected    ? Color.accentColor.opacity(0.2)
                : isHovered   ? Color.primary.opacity(0.06)
                : Color.clear
            )
        )
        .onHover { isHovered = $0 }
        .contextMenu { folderActions }
        .sheet(isPresented: $showRestore) {
            RestoreView(account: account, folder: folder)
                .environmentObject(appState)
                .environmentObject(backupEngine)
        }
        .confirmationDialog(
            "Supprimer la sauvegarde de « \(folder.displayName) » ?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Supprimer", role: .destructive) {
                backupEngine.deleteFolderBackup(for: folder, on: account)
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Tous les fichiers .mbox et l'index seront supprimés. Cette action est irréversible. Les emails restent sur le serveur IMAP.")
        }
    }

    // MARK: - Actions

    /// Sélectionne le dossier et referme l'email ouvert, pour revenir à sa page d'actions.
    private func select() {
        appState.selectedAccountID = account.id
        appState.selectedFolderID = folder.id
        appState.selectedEmail = nil
    }

    /// Source unique des actions : sert au menu du bouton « … » comme au clic droit.
    private var actionItems: [MenuAction] {
        let noBackupDir = appState.backupBaseURL == nil
        return [
            MenuAction("Sauvegarder maintenant",
                       enabled: !isRunning && folder.isEnabled && !noBackupDir) {
                Task { await backupEngine.backupFolder(account: account, folder: folder) }
            },
            MenuAction("Restaurer…", enabled: !isRunning && !noBackupDir) {
                select()
                showRestore = true
            },
            MenuAction("Importer des fichiers mbox…", enabled: !isRunning && !noBackupDir) {
                backupEngine.importMbox(for: folder, on: account)
            },
            .separator,
            MenuAction("Supprimer la sauvegarde…", enabled: !isRunning && !noBackupDir) {
                showDeleteConfirm = true
            },
        ]
    }

    @ViewBuilder
    private var folderActions: some View {
        let items = actionItems
        ForEach(items.indices, id: \.self) { i in
            if items[i].isSeparator {
                Divider()
            } else {
                Button(items[i].title) { items[i].run() }
                    .disabled(!items[i].enabled)
            }
        }
    }

    private var iconName: String {
        let lower = folder.name.lowercased()
        if lower == "inbox" { return "tray.fill" }
        if lower.contains("sent") { return "paperplane.fill" }
        if lower.contains("draft") { return "doc.fill" }
        if lower.contains("trash") || lower.contains("deleted") { return "trash.fill" }
        if lower.contains("junk") || lower.contains("spam") { return "exclamationmark.octagon.fill" }
        if lower.contains("archive") { return "archivebox.fill" }
        return "folder.fill"
    }
}
