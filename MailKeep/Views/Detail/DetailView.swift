import SwiftUI

struct DetailView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var backupEngine: BackupEngine

    var activeProgressForSelection: BackupProgress? {
        appState.activeProgress.values.first {
            $0.accountID == appState.selectedAccountID &&
            (appState.selectedFolder == nil || $0.folderName == appState.selectedFolder?.name)
        }
    }

    var body: some View {
        Group {
            if let progress = activeProgressForSelection {
                ProgressDetailView(progress: progress)
            } else if let folder = appState.selectedFolder,
                      let account = appState.selectedAccount {
                FolderDetailView(account: account, folder: folder)
            } else if let account = appState.selectedAccount {
                AccountDetailView(account: account)
            } else {
                ContentUnavailableView(
                    "MailKeep",
                    systemImage: "tray.and.arrow.down",
                    description: Text("Sélectionnez un compte ou un dossier, puis lancez un backup.")
                )
            }
        }
    }
}

struct FolderDetailView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var backupEngine: BackupEngine
    let account: IMAPAccount
    let folder: MailFolder
    @State private var showRestore = false
    @State private var showDeleteConfirm = false

    /// Vrai uniquement si CE dossier précis est en cours de backup.
    private var isFolderBacking: Bool {
        appState.activeProgress.values.contains {
            $0.accountID == account.id && $0.folderName == folder.name
        }
    }

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "folder.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)
            Text(folder.displayName)
                .font(.title2.bold())
            Text(account.label.isEmpty ? account.host : account.label)
                .foregroundStyle(.secondary)

            if appState.backupBaseURL == nil {
                VStack(spacing: 8) {
                    Text("Aucun dossier de sauvegarde configuré.")
                        .foregroundStyle(.secondary)
                    Button("Choisir un dossier…") {
                        appState.chooseBackupDirectory()
                    }
                }
            } else {
                // Primary actions
                HStack(spacing: 12) {
                    Button {
                        Task { await backupEngine.backupFolder(account: account, folder: folder) }
                    } label: {
                        Label(isFolderBacking ? "Backup en cours…" : "Sauvegarder maintenant",
                              systemImage: isFolderBacking ? "arrow.triangle.2.circlepath" : "arrow.down.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isFolderBacking)   // seulement ce dossier, pas tous les backups

                    Button {
                        showRestore = true
                    } label: {
                        Label("Restaurer…", systemImage: "arrow.up.circle")
                    }
                    .buttonStyle(.bordered)
                }

                // Import — jamais bloqué par un backup d'un autre dossier
                Button {
                    backupEngine.importMbox(for: folder, on: account)
                } label: {
                    Label("Importer des fichiers mbox…", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .disabled(isFolderBacking)
                .help("Copie des fichiers .mbox existants dans le dossier de sauvegarde de ce compte. L'index est mis à jour automatiquement.")

                Divider()
                    .frame(maxWidth: 200)

                // Danger zone
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("Supprimer la sauvegarde…", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .disabled(isFolderBacking)
                .help("Supprime tous les fichiers .mbox et l'index de ce dossier. Les emails sur le serveur IMAP ne sont pas affectés.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
}

struct AccountDetailView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var backupEngine: BackupEngine
    let account: IMAPAccount

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "envelope.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)
            Text(account.label.isEmpty ? account.host : account.label)
                .font(.title2.bold())
            Text(account.username)
                .foregroundStyle(.secondary)
            Text("\(account.folders.filter(\.isEnabled).count) dossier(s) actifs")
                .foregroundStyle(.secondary)

            Button {
                Task { await backupEngine.backupAccount(account) }
            } label: {
                Label("Sauvegarder ce compte", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(appState.isRunningBackup || appState.backupBaseURL == nil)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
