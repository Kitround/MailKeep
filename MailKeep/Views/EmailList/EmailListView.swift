import SwiftUI

struct EmailListView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var loader = EmailLoader()

    let account: IMAPAccount
    let folder: MailFolder
    let mboxURLs: [URL]
    let indexURL: URL?

    private var isFolderBacking: Bool {
        appState.activeProgress.values.contains {
            $0.accountID == account.id && $0.folderName == folder.name
        }
    }

    var body: some View {
        Group {
            if loader.visibleEmails.isEmpty && isFolderBacking {
                // Backup en cours et rien à afficher encore
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Backup en cours…")
                        .foregroundStyle(.secondary)
                    Text("Les emails apparaîtront à la fin du backup.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            } else if loader.visibleEmails.isEmpty && loader.isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Chargement…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            } else if let err = loader.error {
                ContentUnavailableView(
                    "Erreur de lecture",
                    systemImage: "exclamationmark.triangle",
                    description: Text(err)
                )

            } else if loader.visibleEmails.isEmpty {
                ContentUnavailableView(
                    loader.isSearching ? "Aucun résultat" : "Aucun email",
                    systemImage: loader.isSearching ? "magnifyingglass" : "tray",
                    description: Text(loader.isSearching
                        ? "Aucun email ne correspond à « \(loader.searchQuery) »."
                        : isFolderBacking
                            ? "Le backup est en cours, les emails apparaîtront à la fin."
                            : "Le dossier de sauvegarde est vide.")
                )

            } else {
                List {
                    ForEach(loader.visibleEmails) { email in
                        EmailRowView(email: email)
                            .contentShape(Rectangle())
                            .listRowBackground(
                                appState.selectedEmail?.id == email.id
                                    ? Color.accentColor.opacity(0.12)
                                    : Color.clear
                            )
                            .onTapGesture {
                                // Show selection immediately; parsed body arrives via the callback.
                                appState.selectedEmail = loader.resolveBody(for: email) { parsed in
                                    if appState.selectedEmail?.id == parsed.id {
                                        appState.selectedEmail = parsed
                                    }
                                }
                            }
                    }

                    // Sentinel "load more" en bas de liste
                    if loader.hasMore {
                        HStack {
                            Spacer()
                            if loader.isLoading {
                                ProgressView()
                            } else {
                                Text("\(loader.totalCount - loader.visibleEmails.count) emails de plus")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .listRowBackground(Color.clear)
                        .onAppear { loader.loadMore() }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(navigationTitle)
        .searchable(text: Binding(
            get: { loader.searchQuery },
            set: { loader.applySearch($0) }
        ), prompt: "Rechercher dans les emails")
        .toolbar {
            ToolbarItem {
                Button {
                    loader.reload(mboxURLs: mboxURLs, indexURL: indexURL)
                } label: {
                    Label("Rafraîchir", systemImage: "arrow.clockwise")
                }
                .disabled(loader.isLoading || isFolderBacking)
            }
        }
        .onAppear { loader.load(mboxURLs: mboxURLs, indexURL: indexURL) }
        .onChange(of: folder.id) { _, _ in loader.reload(mboxURLs: mboxURLs, indexURL: indexURL) }
        .onChange(of: isFolderBacking) { _, isRunning in
            if !isRunning { loader.reload(mboxURLs: mboxURLs, indexURL: indexURL) }
        }
    }

    private var navigationTitle: String {
        if isFolderBacking { return "\(folder.displayName) — backup en cours…" }
        if loader.isSearching {
            return "\(loader.visibleEmails.count) résultat\(loader.visibleEmails.count == 1 ? "" : "s")"
        }
        if loader.isLoading && loader.totalCount > 0 {
            return "\(folder.displayName) — \(loader.totalCount) chargés…"
        }
        let n = loader.totalCount
        return "\(folder.displayName) — \(n) email\(n == 1 ? "" : "s")"
    }
}
