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

            // Folder actions — the same entries as the detail page, reachable even while
            // an email is open.
            // A button strictly identical to the account's gear (same label, same padding),
            // so alignment and colours come for free. A SwiftUI Menu would not do — its
            // chrome offsets the glyph and turns it black in dark mode.
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

    /// Selects the folder and closes the open email, to come back to its action page.
    private func select() {
        appState.selectedAccountID = account.id
        appState.selectedFolderID = folder.id
        appState.selectedEmail = nil
    }

    /// Single source of the actions: feeds the "…" button's menu and the right-click menu alike.
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
