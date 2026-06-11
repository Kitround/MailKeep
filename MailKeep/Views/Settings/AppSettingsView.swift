import SwiftUI

struct AppSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var stateStore = StateStore()
    @State private var cacheSize: Int64 = 0
    @State private var showResetAllConfirm = false
    @State private var showClearHistoryConfirm = false
    @State private var accountToReset: IMAPAccount? = nil

    var body: some View {
        TabView {
            storageTab
                .tabItem { Label("Stockage", systemImage: "folder") }

            cacheTab
                .tabItem { Label("Cache", systemImage: "internaldrive") }

            historyTab
                .tabItem { Label("Historique", systemImage: "clock") }
        }
        .frame(width: 480, height: 320)
        .onAppear { refreshCacheSize() }
    }

    // MARK: - Stockage

    private var storageTab: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Dossier de sauvegarde")
                            .fontWeight(.medium)
                        if let url = appState.backupBaseURL {
                            Text(url.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        } else {
                            Text("Non défini")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    Spacer()
                    Button("Choisir…") {
                        appState.chooseBackupDirectory()
                    }
                }
            } footer: {
                Text("Les fichiers .mbox sont organisés par compte et dossier, puis par année et mois (ex. INBOX_2024-03.mbox).")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Cache

    private var cacheTab: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("UIDs sauvegardés")
                            .fontWeight(.medium)
                        Text("Taille du cache : \(formatSize(cacheSize))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Tout réinitialiser…") {
                        showResetAllConfirm = true
                    }
                    .foregroundStyle(.red)
                    .disabled(appState.isRunningBackup)
                }
            } footer: {
                Text("Le cache mémorise les UIDs déjà téléchargés. Le réinitialiser force un re-téléchargement complet au prochain backup.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            if !appState.accounts.isEmpty {
                Section("Par compte") {
                    ForEach(appState.accounts) { account in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.label.isEmpty ? account.host : account.label)
                                    .fontWeight(.medium)
                                Text(account.username)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Réinitialiser") {
                                accountToReset = account
                            }
                            .foregroundStyle(.orange)
                            .disabled(appState.isRunningBackup)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .confirmationDialog(
            "Réinitialiser tout le cache ?",
            isPresented: $showResetAllConfirm,
            titleVisibility: .visible
        ) {
            Button("Réinitialiser", role: .destructive) {
                stateStore.wipeAll()
                refreshCacheSize()
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Le prochain backup re-téléchargera tous les messages depuis le serveur IMAP.")
        }
        .confirmationDialog(
            "Réinitialiser le cache de \(accountToReset.map { $0.label.isEmpty ? $0.host : $0.label } ?? "") ?",
            isPresented: Binding(get: { accountToReset != nil }, set: { if !$0 { accountToReset = nil } }),
            titleVisibility: .visible
        ) {
            Button("Réinitialiser", role: .destructive) {
                if let account = accountToReset {
                    stateStore.wipeAccount(accountID: account.id)
                    refreshCacheSize()
                }
                accountToReset = nil
            }
            Button("Annuler", role: .cancel) { accountToReset = nil }
        } message: {
            Text("Le prochain backup re-téléchargera tous les messages de ce compte.")
        }
    }

    // MARK: - Historique

    private var historyTab: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Historique des backups")
                            .fontWeight(.medium)
                        Text("\(appState.backupRuns.count) entrée\(appState.backupRuns.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Vider l'historique…") {
                        showClearHistoryConfirm = true
                    }
                    .foregroundStyle(.red)
                    .disabled(appState.backupRuns.isEmpty)
                }
            } footer: {
                Text("Supprime uniquement l'historique affiché. Les fichiers .mbox ne sont pas affectés.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .padding()
        .confirmationDialog(
            "Vider tout l'historique ?",
            isPresented: $showClearHistoryConfirm,
            titleVisibility: .visible
        ) {
            Button("Vider", role: .destructive) { appState.clearHistory() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Les fichiers .mbox de sauvegarde ne seront pas supprimés.")
        }
    }

    // MARK: - Helpers

    private func refreshCacheSize() {
        cacheSize = stateStore.cacheSize()
    }

    private func formatSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
