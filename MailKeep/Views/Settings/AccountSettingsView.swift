import SwiftUI

struct AccountSettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss

    @State var account: IMAPAccount
    let isNew: Bool

    @State private var password: String = ""
    @State private var isTestingConnection = false
    @State private var testResult: String? = nil
    @State private var testSuccess = false
    @State private var showFolderPicker = false
    @State private var isSaving = false

    private let keychain = KeychainStore()

    var body: some View {
        NavigationStack {
            Form {
                Section("Compte") {
                    TextField("Nom affiché", text: $account.label)
                        .textFieldStyle(.roundedBorder)
                    TextField("Serveur IMAP (ex. imap.gmail.com)", text: $account.host)
                        .textFieldStyle(.roundedBorder)
                    LabeledContent("Sécurité") {
                        Text("IMAPS — TLS (port 993)")
                            .foregroundStyle(.secondary)
                    }
                    TextField("Identifiant / Email", text: $account.username)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                    SecureField("Mot de passe", text: $password)
                        .textFieldStyle(.roundedBorder)
                }

                Section("Messages à sauvegarder") {
                    Picker("Filtre", selection: $account.messageFilter) {
                        ForEach(MessageFilter.allCases, id: \.self) { filter in
                            Text(filter.displayName).tag(filter)
                        }
                    }
                    Text(filterHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Dossiers à sauvegarder") {
                    if account.folders.isEmpty {
                        Text("Aucun dossier sélectionné")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach($account.folders) { $folder in
                            Toggle(folder.displayName, isOn: $folder.isEnabled)
                        }
                    }
                    Button("Sélectionner les dossiers…") {
                        showFolderPicker = true
                    }
                    .disabled(account.host.isEmpty || account.username.isEmpty || password.isEmpty)
                }

                Section("Backup automatique") {
                    Toggle("Activer les backups automatiques", isOn: $account.schedule.isEnabled)
                    if account.schedule.isEnabled {
                        Picker("Intervalle", selection: $account.schedule.intervalMinutes) {
                            ForEach(BackupSchedule.intervalOptions, id: \.minutes) { opt in
                                Text(opt.label).tag(opt.minutes)
                            }
                        }
                        if let last = account.schedule.lastBackupDate {
                            LabeledContent("Dernier backup") {
                                Text(last, format: .dateTime.day().month(.abbreviated).year().hour().minute())
                            }
                        }
                        if let next = account.schedule.nextBackupDate {
                            LabeledContent("Prochain backup") {
                                Text(next, format: .dateTime.day().month(.abbreviated).year().hour().minute())
                            }
                        }
                    }
                }

                Section {
                    HStack(spacing: 12) {
                        Button(isTestingConnection ? "Test en cours…" : "Tester la connexion") {
                            testConnection()
                        }
                        .disabled(isTestingConnection || account.host.isEmpty || account.username.isEmpty || password.isEmpty)

                        if let result = testResult {
                            Label(result, systemImage: testSuccess ? "checkmark.circle" : "xmark.circle")
                                .foregroundStyle(testSuccess ? .green : .red)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isNew ? "Nouveau compte" : "Modifier le compte")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Enregistrement…" : "Enregistrer") {
                        save()
                    }
                    .disabled(account.host.isEmpty || account.username.isEmpty || password.isEmpty || isSaving)
                }
            }
            .sheet(isPresented: $showFolderPicker) {
                FolderPickerView(account: $account, password: password)
                    .environmentObject(appState)
            }
        }
        .frame(minWidth: 480, minHeight: 520)
        .onAppear {
            password = (try? keychain.load(for: account)) ?? ""
        }
    }

    private var filterHint: String {
        switch account.messageFilter {
        case .all:     return "Tous les messages du dossier seront sauvegardés."
        case .seen:    return "Seuls les messages déjà lus sont sauvegardés. Les non lus seront ignorés jusqu'à leur lecture."
        case .unseen:  return "Seuls les messages non lus sont sauvegardés."
        case .flagged: return "Seuls les messages marqués (drapeau) sont sauvegardés."
        }
    }

    private func testConnection() {
        isTestingConnection = true
        testResult = nil
        Task {
            do {
                let client = IMAPClient()
                try await client.connect(host: account.host, port: account.port)
                try await client.login(username: account.username, password: password)
                try await client.logout()
                await MainActor.run {
                    testResult = "Connexion réussie"
                    testSuccess = true
                    isTestingConnection = false
                }
            } catch {
                await MainActor.run {
                    testResult = error.localizedDescription
                    testSuccess = false
                    isTestingConnection = false
                }
            }
        }
    }

    private func save() {
        isSaving = true
        do {
            try keychain.save(password: password, for: account)
            if isNew {
                appState.addAccount(account)
            } else {
                appState.updateAccount(account)
            }
            dismiss()
        } catch {
            testResult = "Erreur Keychain : \(error.localizedDescription)"
            testSuccess = false
        }
        isSaving = false
    }
}
