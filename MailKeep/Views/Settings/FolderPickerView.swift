import SwiftUI

struct FolderPickerView: View {
    @Environment(\.dismiss) var dismiss
    @Binding var account: IMAPAccount
    let password: String

    @State private var availableFolders: [String] = []
    @State private var selectedNames: Set<String> = []
    @State private var isLoading = true
    @State private var error: String? = nil
    @State private var phase: LoadPhase = .connecting

    private enum LoadPhase {
        case connecting, authenticating, listing
        var label: String {
            switch self {
            case .connecting:     return "Connexion au serveur…"
            case .authenticating: return "Authentification…"
            case .listing:        return "Récupération des dossiers…"
            }
        }
        var systemImage: String {
            switch self {
            case .connecting:     return "network"
            case .authenticating: return "lock.shield"
            case .listing:        return "folder"
            }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    loadingView
                } else if let err = error {
                    ContentUnavailableView(
                        "Erreur",
                        systemImage: "exclamationmark.triangle",
                        description: Text(err)
                    )
                } else {
                    List(availableFolders, id: \.self, selection: $selectedNames) { name in
                        let folder = MailFolder(name: name)
                        HStack {
                            Image(systemName: selectedNames.contains(name) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedNames.contains(name) ? Color.accentColor : Color.secondary)
                            Text(folder.displayName)
                            if folder.displayName != name {
                                Text(name).font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if selectedNames.contains(name) {
                                selectedNames.remove(name)
                            } else {
                                selectedNames.insert(name)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Sélectionner les dossiers")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Confirmer") {
                        applySelection()
                        dismiss()
                    }
                    .disabled(selectedNames.isEmpty)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 460)
        .task { await loadFolders() }
    }

    // MARK: - Loading view

    private var loadingView: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 88, height: 88)
                Image(systemName: phase.systemImage)
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(Color.accentColor)
                    .symbolEffect(.pulse, options: .repeating)
            }

            VStack(spacing: 6) {
                Text(phase.label)
                    .font(.headline)
                Text(account.host)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospaced()
            }

            ProgressView()
                .controlSize(.small)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 8) {
                phaseRow(.connecting,     done: phase != .connecting)
                phaseRow(.authenticating, done: phase == .listing)
                phaseRow(.listing,        done: false)
            }
            .padding(.top, 8)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }

    private func phaseRow(_ p: LoadPhase, done: Bool) -> some View {
        let isCurrent = p == phase
        return HStack(spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : (isCurrent ? "circle.dotted" : "circle"))
                .foregroundStyle(done ? .green : (isCurrent ? Color.accentColor : .secondary))
                .symbolEffect(.pulse, options: .repeating, isActive: isCurrent)
                .frame(width: 18)
            Text(p.label)
                .font(.callout)
                .foregroundStyle(isCurrent ? .primary : .secondary)
            Spacer()
        }
    }

    // MARK: - Network

    private func loadFolders() async {
        isLoading = true
        error = nil
        do {
            await MainActor.run { phase = .connecting }
            let client = IMAPClient()
            try await client.connect(host: account.host, port: account.port)

            await MainActor.run { phase = .authenticating }
            try await client.login(username: account.username, password: password)

            await MainActor.run { phase = .listing }
            let folders = try await client.listFolders()
            try await client.logout()

            await MainActor.run {
                availableFolders = folders.sorted()
                selectedNames = Set(account.folders.map(\.name))
                isLoading = false
            }
        } catch {
            await MainActor.run {
                self.error = error.localizedDescription
                isLoading = false
            }
        }
    }

    private func applySelection() {
        var result: [MailFolder] = []
        for name in availableFolders where selectedNames.contains(name) {
            if let existing = account.folders.first(where: { $0.name == name }) {
                result.append(existing)
            } else {
                result.append(MailFolder(name: name))
            }
        }
        account.folders = result
    }
}
