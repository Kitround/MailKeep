import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {
    @Published var accounts: [IMAPAccount] = []
    @Published var backupRuns: [BackupRun] = []
    @Published var activeProgress: [UUID: BackupProgress] = [:]
    @Published var selectedAccountID: UUID? = nil
    @Published var selectedFolderID: UUID? = nil
    @Published var selectedEmail: EmailMessage? = nil
    @Published var backupBaseURL: URL? = nil

    private let accountsKey = "mailkeep_accounts"
    private let runsKey = "mailkeep_runs"
    private let bookmarkKey = "mailkeep_backup_bookmark"

    init() { load() }

    var selectedAccount: IMAPAccount? {
        accounts.first { $0.id == selectedAccountID }
    }

    var selectedFolder: MailFolder? {
        selectedAccount?.folders.first { $0.id == selectedFolderID }
    }

    var isRunningBackup: Bool { !activeProgress.isEmpty }

    var selectedMboxURLs: [URL] {
        guard let account = selectedAccount, let folder = selectedFolder,
              let base = backupBaseURL else { return [] }
        return MboxStore.mboxURLs(baseDir: base, account: account, folderName: folder.name)
    }

    var selectedIndexURL: URL? {
        guard let account = selectedAccount, let folder = selectedFolder,
              let base = backupBaseURL else { return nil }
        return MboxStore.indexURL(baseDir: base, account: account, folderName: folder.name)
    }


    func save() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: accountsKey)
        }
        let recentRuns = Array(backupRuns.suffix(500))
        if let data = try? JSONEncoder().encode(recentRuns) {
            UserDefaults.standard.set(data, forKey: runsKey)
        }
    }

    func load() {
        if let data = UserDefaults.standard.data(forKey: accountsKey),
           let decoded = try? JSONDecoder().decode([IMAPAccount].self, from: data) {
            accounts = decoded
        }
        if let data = UserDefaults.standard.data(forKey: runsKey),
           let decoded = try? JSONDecoder().decode([BackupRun].self, from: data) {
            let knownIDs = Set(accounts.map(\.id))
            backupRuns = decoded.filter { knownIDs.contains($0.accountID) }
        }
        loadBackupBookmark()
    }

    func clearHistory() {
        backupRuns = []
        save()
    }

    func addAccount(_ account: IMAPAccount) {
        accounts.append(account)
        save()
    }

    func updateAccount(_ account: IMAPAccount) {
        if let idx = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[idx] = account
            save()
        }
    }

    func removeAccount(_ account: IMAPAccount) {
        accounts.removeAll { $0.id == account.id }
        backupRuns.removeAll { $0.accountID == account.id }
        if selectedAccountID == account.id { selectedAccountID = nil }
        save()
    }

    func addRun(_ run: BackupRun) {
        backupRuns.append(run)
        save()
    }

    func updateRun(_ run: BackupRun) {
        if let idx = backupRuns.firstIndex(where: { $0.id == run.id }) {
            backupRuns[idx] = run
            save()
        }
    }

    func runsFor(accountID: UUID, folderName: String? = nil) -> [BackupRun] {
        backupRuns.filter {
            $0.accountID == accountID && (folderName == nil || $0.folderName == folderName)
        }.sorted { $0.startedAt > $1.startedAt }
    }

    func chooseBackupDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choisissez le dossier où stocker les sauvegardes mbox"
        panel.prompt = "Choisir"
        if panel.runModal() == .OK, let url = panel.url {
            backupBaseURL = url
            saveBackupBookmark(url)
        }
    }

    private func saveBackupBookmark(_ url: URL) {
        guard let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }
        UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
    }

    private func loadBackupBookmark() {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        var isStale = false
        if let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) {
            _ = url.startAccessingSecurityScopedResource()
            backupBaseURL = url
            if isStale { saveBackupBookmark(url) }
        }
    }
}
