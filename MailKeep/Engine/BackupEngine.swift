import Foundation
import AppKit
import UniformTypeIdentifiers

@MainActor
final class BackupEngine: ObservableObject {
    weak var appState: AppState?
    private let keychain = KeychainStore()
    private let stateStore = StateStore()

    /// Keys of folders where a stop has been requested (accountID|folderName)
    private var stopRequested: Set<String> = []

    // MARK: - Public API

    /// Lance tous les comptes activés en parallèle (un Task par dossier).
    func backupAll() async {
        guard let state = appState else { return }
        await withTaskGroup(of: Void.self) { group in
            for account in state.accounts where account.isEnabled {
                for folder in account.folders where folder.isEnabled {
                    group.addTask { @MainActor in
                        await self.backupFolder(account: account, folder: folder)
                    }
                }
            }
        }
        // Mise à jour lastBackupDate pour chaque compte
        guard let state = appState else { return }
        for account in state.accounts where account.isEnabled {
            if var updated = state.accounts.first(where: { $0.id == account.id }) {
                updated.schedule.lastBackupDate = Date()
                state.updateAccount(updated)
            }
        }
    }

    /// Lance tous les dossiers d'un compte en parallèle.
    func backupAccount(_ account: IMAPAccount) async {
        await withTaskGroup(of: Void.self) { group in
            for folder in account.folders where folder.isEnabled {
                group.addTask { @MainActor in
                    await self.backupFolder(account: account, folder: folder)
                }
            }
        }
        if var updated = appState?.accounts.first(where: { $0.id == account.id }) {
            updated.schedule.lastBackupDate = Date()
            appState?.updateAccount(updated)
        }
    }

    func backupFolder(account: IMAPAccount, folder: MailFolder) async {
        guard let state = appState, let baseURL = state.backupBaseURL else { return }

        var progress = BackupProgress(
            accountID: account.id,
            accountLabel: account.label,
            folderName: folder.name
        )
        let progressID = progress.id
        state.activeProgress[progressID] = progress

        var run = BackupRun(
            accountID: account.id,
            accountLabel: account.label,
            folderName: folder.name,
            startedAt: Date()
        )
        state.addRun(run)

        do {
            let password = try keychain.load(for: account)

            var client = IMAPClient()

            func reconnect() async throws {
                try? await client.logout()
                client = IMAPClient()
                try await client.connect(host: account.host, port: account.port)
                try await client.login(username: account.username, password: password)
                _ = try await client.selectFolder(folder.name)
            }

            progress.phase = .connecting
            state.activeProgress[progressID] = progress
            try await client.connect(host: account.host, port: account.port)

            progress.phase = .authenticating
            state.activeProgress[progressID] = progress
            try await client.login(username: account.username, password: password)

            progress.phase = .selectingFolder
            state.activeProgress[progressID] = progress
            let folderStatus = try await client.selectFolder(folder.name)

            // UID validity check — si le serveur a réassigné les UIDs, reset complet
            var folderState = stateStore.load(accountID: account.id, folderName: folder.name)
            if let existing = folderState,
               existing.uidValidity != folderStatus.uidValidity,
               folderStatus.uidValidity != 0 {
                stateStore.wipe(accountID: account.id, folderName: folder.name)
                folderState = nil
            }

            progress.phase = .fetchingUIDList
            state.activeProgress[progressID] = progress

            // On récupère les UIDs correspondant au filtre du compte (par défaut SEEN
            // pour rétrocompat), puis on filtre localement avec knownUIDs. UID SEARCH
            // ne télécharge pas les messages — juste une liste d'UIDs, rapide même
            // sur 20 000 messages.
            let knownUIDs = folderState?.backedUpUIDs ?? []
            let serverUIDs = try await client.fetchAllUIDs(filter: account.messageFilter)
            let toFetch = serverUIDs.filter { !knownUIDs.contains($0) }

            progress.total = toFetch.count
            progress.phase = .downloadingMessages
            state.activeProgress[progressID] = progress

            var downloadedUIDs: Set<UInt32> = []
            var bytesWritten: Int64 = 0
            let idxURL = MboxStore.indexURL(baseDir: baseURL, account: account, folderName: folder.name)
            let indexStore = EmailIndexStore(indexURL: idxURL)
            var indexBatch: [EmailIndexEntry] = []

            let key = stopKey(account.id, folder.name)
            var wasStopped = false

            for (index, uid) in toFetch.enumerated() {
                // Check for stop request
                if stopRequested.remove(key) != nil {
                    wasStopped = true
                    break
                }

                progress.current = index + 1
                progress.currentUID = uid
                state.activeProgress[progressID] = progress

                let msg = try await fetchWithRetry(uid: uid, getClient: { client }, reconnect: reconnect)

                let sender = MboxStore.extractSender(from: msg.rfc822)
                let (year, month) = yearMonthFrom(internalDate: msg.internalDate)
                let mboxURL = MboxStore.mboxURL(
                    baseDir: baseURL, account: account,
                    folderName: folder.name, year: year, month: month
                )
                let (fileOffset, fileLength) = try MboxStore.appendMessage(
                    messageData: msg.rfc822,
                    internalDate: msg.internalDate,
                    sender: sender,
                    to: mboxURL
                )
                bytesWritten += Int64(fileLength)
                downloadedUIDs.insert(uid)

                let headerMsg = EmailParser.parseHeadersOnly(data: msg.rfc822)
                indexBatch.append(EmailIndexEntry(
                    id: headerMsg.id,
                    from: headerMsg.from, to: headerMsg.to, cc: headerMsg.cc,
                    subject: headerMsg.subject, date: headerMsg.date,
                    filename: mboxURL.lastPathComponent,
                    offset: fileOffset, length: fileLength,
                    hasAttachments: headerMsg.hasAttachments
                ))

                if downloadedUIDs.count % 50 == 0 {
                    try stateStore.addUIDs(
                        downloadedUIDs,
                        accountID: account.id,
                        folderName: folder.name,
                        uidValidity: folderStatus.uidValidity
                    )
                    downloadedUIDs = []
                    try indexStore.append(indexBatch)
                    indexBatch = []
                }
            }

            // Flush restant — uidNext plus jamais persisté (il cassait la détection
            // des messages passés de non-lus à lus depuis le dernier backup)
            try indexStore.append(indexBatch)
            try stateStore.addUIDs(
                downloadedUIDs,
                accountID: account.id,
                folderName: folder.name,
                uidValidity: folderStatus.uidValidity,
                uidNext: nil
            )

            try? await client.logout()

            if wasStopped {
                progress.phase = .stopped
                state.activeProgress[progressID] = progress
                run.finishedAt = Date()
                run.messagesDownloaded = progress.current
                run.messagesSkipped = folderState?.backedUpUIDs.count ?? 0
                run.bytesWritten = bytesWritten
                run.wasStopped = true
                state.updateRun(run)
            } else {
                progress.phase = .done
                state.activeProgress[progressID] = progress
                run.finishedAt = Date()
                run.messagesDownloaded = toFetch.count
                run.messagesSkipped = folderState?.backedUpUIDs.count ?? 0
                run.bytesWritten = bytesWritten
                state.updateRun(run)
            }

        } catch {
            progress.phase = .failed
            progress.errorMessage = error.localizedDescription
            state.activeProgress[progressID] = progress
            run.finishedAt = Date()
            run.errorMessage = error.localizedDescription
            state.updateRun(run)
        }

        try? await Task.sleep(for: .seconds(2))
        state.activeProgress.removeValue(forKey: progressID)
    }

    // MARK: - Stop

    func requestStop(accountID: UUID, folderName: String) {
        stopRequested.insert(stopKey(accountID, folderName))
    }

    func stopAll() {
        guard let state = appState else { return }
        for p in state.activeProgress.values {
            stopRequested.insert(stopKey(p.accountID, p.folderName))
        }
    }

    func cancelAll() { stopAll() }

    // MARK: - Import

    func importMbox(for folder: MailFolder, on account: IMAPAccount) {
        guard let state = appState, let baseURL = state.backupBaseURL else { return }

        let panel = NSOpenPanel()
        panel.title = "Importer des fichiers mbox"
        panel.message = "Choisissez un ou plusieurs fichiers .mbox à importer dans « \(folder.displayName) »"
        if let mboxType = UTType(filenameExtension: "mbox") {
            panel.allowedContentTypes = [mboxType]
        }
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        guard !urls.isEmpty else { return }

        Task {
            await performImport(urls: urls, folder: folder, account: account, baseURL: baseURL)
        }
    }

    private func performImport(urls: [URL], folder: MailFolder, account: IMAPAccount, baseURL: URL) async {
        guard let state = appState else { return }

        var progress = BackupProgress(
            accountID: account.id,
            accountLabel: account.label,
            folderName: "Import → \(folder.displayName)"
        )
        progress.phase = .importing
        progress.total = urls.count
        let progressID = progress.id
        state.activeProgress[progressID] = progress

        let destDir = MboxStore.accountDir(baseDir: baseURL, account: account)
        let idxURL = MboxStore.indexURL(baseDir: baseURL, account: account, folderName: folder.name)

        do {
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        } catch {
            progress.phase = .failed
            progress.errorMessage = error.localizedDescription
            state.activeProgress[progressID] = progress
            try? await Task.sleep(for: .seconds(2))
            state.activeProgress.removeValue(forKey: progressID)
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: Date())
        let safeFolder = MboxStore.sanitize(folder.name)

        var importedCount = 0
        var errorMessages: [String] = []

        for (i, srcURL) in urls.enumerated() {
            progress.current = i + 1
            state.activeProgress[progressID] = progress

            let accessed = srcURL.startAccessingSecurityScopedResource()
            defer { if accessed { srcURL.stopAccessingSecurityScopedResource() } }

            let suffix = urls.count > 1 ? "\(timestamp)_\(i + 1)" : timestamp
            let destURL = destDir.appendingPathComponent("\(safeFolder)_imported_\(suffix).mbox")

            do {
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.copyItem(at: srcURL, to: destURL)
                importedCount += 1
            } catch {
                errorMessages.append(srcURL.lastPathComponent + ": " + error.localizedDescription)
            }
        }

        try? FileManager.default.removeItem(at: idxURL)

        if errorMessages.isEmpty {
            progress.phase = .done
        } else {
            progress.phase = importedCount > 0 ? .done : .failed
            progress.errorMessage = errorMessages.joined(separator: "\n")
        }
        state.activeProgress[progressID] = progress

        try? await Task.sleep(for: .seconds(2))
        state.activeProgress.removeValue(forKey: progressID)
    }

    // MARK: - Restore

    func restoreFolder(from mboxURL: URL, to folder: MailFolder, on account: IMAPAccount) async {
        guard let state = appState else { return }

        var progress = BackupProgress(
            accountID: account.id,
            accountLabel: account.label,
            folderName: "Restauration → \(folder.displayName)"
        )
        let progressID = progress.id
        state.activeProgress[progressID] = progress

        do {
            let messages = try MboxStore.readMessagesWithInternalDate(from: mboxURL)
            progress.total = messages.count
            state.activeProgress[progressID] = progress

            let client = IMAPClient()
            progress.phase = .connecting
            state.activeProgress[progressID] = progress
            try await client.connect(host: account.host, port: account.port)
            progress.phase = .authenticating
            state.activeProgress[progressID] = progress
            let password = try keychain.load(for: account)
            try await client.login(username: account.username, password: password)

            progress.phase = .downloadingMessages
            for (i, item) in messages.enumerated() {
                progress.current = i + 1
                state.activeProgress[progressID] = progress
                try await client.appendMessage(to: folder.name, data: item.data, internalDate: item.internalDate)
            }

            try await client.logout()
            progress.phase = .done
            state.activeProgress[progressID] = progress

        } catch {
            progress.phase = .failed
            progress.errorMessage = error.localizedDescription
            state.activeProgress[progressID] = progress
        }

        try? await Task.sleep(for: .seconds(2))
        state.activeProgress.removeValue(forKey: progressID)
    }

    func restoreMessage(_ email: EmailMessage, to folder: MailFolder, on account: IMAPAccount) async {
        guard let state = appState else { return }

        var progress = BackupProgress(
            accountID: account.id,
            accountLabel: account.label,
            folderName: "Restauration → \(folder.displayName)"
        )
        progress.total = 1
        let progressID = progress.id
        state.activeProgress[progressID] = progress

        do {
            let data: Data
            if let url = email.mboxFileURL, email.mboxLength > 0 {
                data = try MboxStore.readMessage(at: email.mboxOffset, length: email.mboxLength, from: url)
            } else if let raw = email.rawData {
                data = raw
            } else {
                throw RestoreError.noData
            }

            let client = IMAPClient()
            progress.phase = .connecting
            state.activeProgress[progressID] = progress
            try await client.connect(host: account.host, port: account.port)

            progress.phase = .authenticating
            state.activeProgress[progressID] = progress
            let password = try keychain.load(for: account)
            try await client.login(username: account.username, password: password)

            progress.phase = .downloadingMessages
            progress.current = 1
            state.activeProgress[progressID] = progress
            let internalDate = email.date.map { MboxStore.imapDate(from: $0) }
            try await client.appendMessage(to: folder.name, data: data, internalDate: internalDate)

            try? await client.logout()
            progress.phase = .done
            state.activeProgress[progressID] = progress

        } catch {
            progress.phase = .failed
            progress.errorMessage = error.localizedDescription
            state.activeProgress[progressID] = progress
        }

        try? await Task.sleep(for: .seconds(2))
        state.activeProgress.removeValue(forKey: progressID)
    }

    // MARK: - Retry helper

    private func fetchWithRetry(
        uid: UInt32,
        getClient: () -> IMAPClient,
        reconnect: () async throws -> Void
    ) async throws -> FetchedMessage {
        var lastError: Error = IMAPError.serverDisconnected
        for attempt in 1...3 {
            do {
                return try await getClient().fetchMessage(uid: uid)
            } catch {
                lastError = error
                guard attempt < 3 else { break }
                try? await Task.sleep(for: .milliseconds(500))
                try await reconnect()
            }
        }
        throw lastError
    }

    // MARK: - Delete folder backup

    func deleteFolderBackup(for folder: MailFolder, on account: IMAPAccount) {
        guard let state = appState, let baseURL = state.backupBaseURL else { return }

        let accountDir = MboxStore.accountDir(baseDir: baseURL, account: account)
        let idxURL = MboxStore.indexURL(baseDir: baseURL, account: account, folderName: folder.name)
        let safeFolder = MboxStore.sanitize(folder.name)
        let fm = FileManager.default

        try? fm.removeItem(at: idxURL)

        if let contents = try? fm.contentsOfDirectory(at: accountDir, includingPropertiesForKeys: nil) {
            for url in contents where url.pathExtension == "mbox"
                && url.lastPathComponent.hasPrefix(safeFolder) {
                try? fm.removeItem(at: url)
            }
        }

        stateStore.wipe(accountID: account.id, folderName: folder.name)

        if state.selectedAccountID == account.id && state.selectedFolderID == folder.id {
            state.selectedEmail = nil
        }
        state.objectWillChange.send()
    }

    // MARK: - Helpers

    private func stopKey(_ accountID: UUID, _ folderName: String) -> String {
        "\(accountID)|\(folderName)"
    }

    private func yearMonthFrom(internalDate: String) -> (Int, Int) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d-MMM-yyyy HH:mm:ss Z"
        let date = formatter.date(from: internalDate.trimmingCharacters(in: .whitespaces)) ?? Date()
        let comps = Calendar.current.dateComponents([.year, .month], from: date)
        return (comps.year ?? Calendar.current.component(.year, from: Date()),
                comps.month ?? Calendar.current.component(.month, from: Date()))
    }
}

enum RestoreError: LocalizedError {
    case noData
    var errorDescription: String? { "Données du message introuvables dans le fichier mbox." }
}
