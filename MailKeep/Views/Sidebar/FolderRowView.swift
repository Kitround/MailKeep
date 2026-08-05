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
            // Métriques calquées sur la roue crantée de AccountRowView pour
            // que les deux icônes s'alignent verticalement dans la sidebar.
            Menu {
                folderActions
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.body)
                    .foregroundStyle(isHovered ? .primary : .secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
            .opacity(isHovered ? 1 : 0.5)
            .padding(.trailing, 8)
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

    @ViewBuilder
    private var folderActions: some View {
        Button("Sauvegarder maintenant") {
            Task { await backupEngine.backupFolder(account: account, folder: folder) }
        }
        .disabled(isRunning || !folder.isEnabled || appState.backupBaseURL == nil)

        Button("Restaurer…") {
            select()
            showRestore = true
        }
        .disabled(isRunning || appState.backupBaseURL == nil)

        Button("Importer des fichiers mbox…") {
            backupEngine.importMbox(for: folder, on: account)
        }
        .disabled(isRunning || appState.backupBaseURL == nil)

        Divider()

        Button("Supprimer la sauvegarde…", role: .destructive) {
            showDeleteConfirm = true
        }
        .disabled(isRunning || appState.backupBaseURL == nil)
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
