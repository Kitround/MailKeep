import SwiftUI

/// Sheet permettant de restaurer un unique message vers un compte/dossier IMAP choisi.
struct RestoreMessageView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var backupEngine: BackupEngine
    @Environment(\.dismiss) var dismiss

    let email: EmailMessage

    @State private var selectedAccountID: UUID? = nil
    @State private var selectedFolderName: String = ""
    @State private var isRestoring = false

    private var selectedAccount: IMAPAccount? {
        appState.accounts.first { $0.id == selectedAccountID }
    }

    private var availableFolders: [MailFolder] {
        selectedAccount?.folders ?? []
    }

    private var selectedFolder: MailFolder? {
        availableFolders.first { $0.name == selectedFolderName }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Titre
            HStack {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Restaurer ce message")
                        .font(.headline)
                    Text(email.subject)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Divider()

            // Résumé du message
            GroupBox("Message à restaurer") {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 5) {
                    if !email.from.isEmpty {
                        infoRow(label: "De", value: email.from)
                    }
                    infoRow(label: "Sujet", value: email.subject)
                    if let date = email.date {
                        infoRow(label: "Date", value: date.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                .padding(.top, 4)
            }

            // Sélection destination
            GroupBox("Destination IMAP") {
                VStack(alignment: .leading, spacing: 10) {
                    // Compte
                    Picker("Compte", selection: $selectedAccountID) {
                        Text("Choisir un compte…").tag(Optional<UUID>.none)
                        ForEach(appState.accounts) { account in
                            Text(account.label.isEmpty ? account.host : account.label)
                                .tag(Optional(account.id))
                        }
                    }
                    .onChange(of: selectedAccountID) { _, _ in
                        // Pré-sélectionner le premier dossier
                        selectedFolderName = selectedAccount?.folders.first?.name ?? ""
                    }

                    // Dossier
                    Picker("Dossier", selection: $selectedFolderName) {
                        if availableFolders.isEmpty {
                            Text("—").tag("")
                        }
                        ForEach(availableFolders) { folder in
                            Text(folder.displayName).tag(folder.name)
                        }
                    }
                    .disabled(selectedAccountID == nil)
                }
                .padding(.top, 4)
            }

            Spacer()

            // Boutons
            HStack {
                Button("Annuler") { dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.escape)
                Spacer()
                Button {
                    guard let account = selectedAccount, let folder = selectedFolder else { return }
                    isRestoring = true
                    Task {
                        await backupEngine.restoreMessage(email, to: folder, on: account)
                        dismiss()
                    }
                } label: {
                    if isRestoring {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Restaurer", systemImage: "arrow.up.circle.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedAccount == nil || selectedFolder == nil || isRestoring)
                .keyboardShortcut(.return)
            }
        }
        .padding(24)
        .frame(width: 440)
        .onAppear { preselect() }
    }

    // MARK: - Helpers

    private func preselect() {
        // Pré-sélectionner le compte courant si possible
        if let account = appState.selectedAccount {
            selectedAccountID = account.id
            selectedFolderName = appState.selectedFolder?.name ?? account.folders.first?.name ?? ""
        } else if let first = appState.accounts.first {
            selectedAccountID = first.id
            selectedFolderName = first.folders.first?.name ?? ""
        }
    }

    @ViewBuilder
    private func infoRow(label: String, value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .font(.caption)
                .gridColumnAlignment(.trailing)
            Text(value)
                .font(.caption)
                .lineLimit(1)
        }
    }
}
