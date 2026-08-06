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

    /// A pending .eml archive: re-read the message from the mbox we just wrote
    /// (tiny footprint) and build the archive off the critical download path.
    private struct ArchiveJob: Sendable {
        let mboxURL: URL
        let offset: Int64
        let length: Int
        let archiveURL: URL
    }

    // MARK: - Public API

    /// Lance les comptes activés en parallèle, mais leurs dossiers l'un après l'autre :
    /// chaque dossier ouvre sa propre connexion IMAP et les serveurs plafonnent le nombre
    /// de connexions simultanées par compte (Posteo ~10, Gmail 15).
    func backupAll() async {
        guard let state = appState else { return }
        var succeededAccounts: Set<UUID> = []
        await withTaskGroup(of: (UUID, Bool).self) { group in
            for account in state.accounts where account.isEnabled {
                group.addTask { @MainActor in
                    var ok = false
                    for folder in account.folders where folder.isEnabled {
                        if await self.backupFolder(account: account, folder: folder) { ok = true }
                    }
                    return (account.id, ok)
                }
            }
            for await (accountID, ok) in group where ok {
                succeededAccounts.insert(accountID)
            }
        }
        // lastBackupDate uniquement si au moins un dossier a réussi — un backup
        // planifié qui échoue (serveur down, mot de passe) sera retenté au prochain tick.
        guard let state = appState else { return }
        for account in state.accounts where succeededAccounts.contains(account.id) {
            var updated = account
            updated.schedule.lastBackupDate = Date()
            state.updateAccount(updated)
        }
    }

    /// Lance les dossiers d'un compte l'un après l'autre — une seule connexion IMAP
    /// ouverte à la fois vers ce serveur.
    func backupAccount(_ account: IMAPAccount) async {
        var anySuccess = false
        for folder in account.folders where folder.isEnabled {
            if await backupFolder(account: account, folder: folder) { anySuccess = true }
        }
        if anySuccess, var updated = appState?.accounts.first(where: { $0.id == account.id }) {
            updated.schedule.lastBackupDate = Date()
            appState?.updateAccount(updated)
        }
    }

    /// Returns true if the run completed (including a clean user stop), false on error.
    @discardableResult
    func backupFolder(account: IMAPAccount, folder: MailFolder) async -> Bool {
        guard let state = appState, let baseURL = state.backupBaseURL else { return false }

        // Un Stop demandé hors de la boucle (pendant la connexion, le flush final, ou sur
        // un run qui a échoué) restait armé et arrêtait le run suivant au premier message.
        stopRequested.remove(stopKey(account.id, folder.name))

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
        var succeeded = false

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
            // Index gardé en mémoire pendant tout le run — l'ancien append() relisait
            // et réécrivait le JSON complet à chaque flush (O(n²) sur les gros dossiers).
            var indexEntries = toFetch.isEmpty ? [] : indexStore.load()
            var newEntriesSinceFlush = 0
            var archiveJobs: [ArchiveJob] = []

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

                let (year, month) = MboxStore.yearMonth(fromInternalDate: msg.internalDate)
                let mboxURL = MboxStore.mboxURL(
                    baseDir: baseURL, account: account,
                    folderName: folder.name, year: year, month: month
                )
                // Écriture mbox + parsing des en-têtes hors du main actor : sur un mail
                // à grosses pièces jointes, les faire ici gelait l'interface.
                let written = try await Task.detached(priority: .userInitiated) {
                    try Self.writeMessage(msg.rfc822, internalDate: msg.internalDate, to: mboxURL)
                }.value
                let fileOffset = written.offset
                let fileLength = written.length
                bytesWritten += Int64(fileLength)
                downloadedUIDs.insert(uid)

                if account.archiveFullContent {
                    // Don't archive inline — it blocks the download loop on network.
                    // Queue it; the archive phase below runs it in parallel, off-path.
                    let archiveURL = MboxStore.archiveURL(
                        baseDir: baseURL, account: account,
                        mboxFilename: mboxURL.lastPathComponent, offset: fileOffset
                    )
                    archiveJobs.append(ArchiveJob(
                        mboxURL: mboxURL, offset: fileOffset, length: fileLength, archiveURL: archiveURL
                    ))
                }

                indexEntries.append(EmailIndexEntry(
                    id: UUID(),
                    from: written.from, to: written.to, cc: written.cc,
                    subject: written.subject, date: written.date,
                    filename: mboxURL.lastPathComponent,
                    offset: fileOffset, length: fileLength,
                    hasAttachments: written.hasAttachments
                ))
                newEntriesSinceFlush += 1

                if downloadedUIDs.count % 50 == 0 {
                    try await flushUIDs(downloadedUIDs, account: account, folder: folder,
                                        uidValidity: folderStatus.uidValidity)
                    downloadedUIDs = []
                }
                if newEntriesSinceFlush >= 250 {
                    try await save(indexEntries, to: indexStore)
                    newEntriesSinceFlush = 0
                }
            }

            // Flush restant
            if newEntriesSinceFlush > 0 {
                try await save(indexEntries, to: indexStore)
            }
            try await flushUIDs(downloadedUIDs, account: account, folder: folder,
                                uidValidity: folderStatus.uidValidity)

            try? await client.logout()

            // Archive phase — decoupled from the download loop so the backup runs at
            // full speed. Each .eml is built off the main actor, several in parallel,
            // re-reading the message from the .mbox just written (tiny memory footprint).
            if !wasStopped, account.archiveFullContent, !archiveJobs.isEmpty {
                progress.phase = .archiving
                progress.total = archiveJobs.count
                progress.current = 0
                progress.currentUID = nil
                state.activeProgress[progressID] = progress

                var jobIterator = archiveJobs.makeIterator()
                var completed = 0
                let maxConcurrent = 4
                await withTaskGroup(of: Void.self) { group in
                    var inFlight = 0
                    for _ in 0..<maxConcurrent {
                        guard let job = jobIterator.next() else { break }
                        group.addTask { await BackupEngine.runArchive(job) }
                        inFlight += 1
                    }
                    while inFlight > 0 {
                        await group.next()
                        inFlight -= 1
                        completed += 1
                        progress.current = completed
                        state.activeProgress[progressID] = progress
                        // Stop respected between launches; in-flight archives finish.
                        if stopRequested.remove(key) == nil, let job = jobIterator.next() {
                            group.addTask { await BackupEngine.runArchive(job) }
                            inFlight += 1
                        }
                    }
                }
            }

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
            succeeded = true

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
        return succeeded
    }

    // MARK: - Stop

    func requestStop(accountID: UUID, folderName: String) {
        stopRequested.insert(stopKey(accountID, folderName))
    }

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
            // Positions seules : le contenu est relu message par message, un mbox de
            // plusieurs gigaoctets ne doit jamais tenir en mémoire d'un bloc.
            let ranges = try await Task.detached { try MboxStore.messageRanges(in: mboxURL) }.value
            progress.total = ranges.count
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
            // Un message refusé par le serveur ne doit pas interrompre tout le restore.
            // En revanche, des échecs consécutifs (connexion morte) font abandonner.
            var failedCount = 0
            var consecutiveFailures = 0
            for (i, range) in ranges.enumerated() {
                progress.current = i + 1
                state.activeProgress[progressID] = progress
                let item = try await Task.detached {
                    try MboxStore.readMessageWithInternalDate(
                        at: range.offset, length: range.length, from: mboxURL
                    )
                }.value
                guard !item.data.isEmpty else { continue }
                do {
                    try await client.appendMessage(to: folder.name, data: item.data, internalDate: item.internalDate)
                    consecutiveFailures = 0
                } catch {
                    failedCount += 1
                    consecutiveFailures += 1
                    if consecutiveFailures >= 5 { throw error }
                }
            }

            try await client.logout()
            progress.phase = .done
            if failedCount > 0 {
                progress.errorMessage = "\(failedCount) message(s) refusé(s) par le serveur."
            }
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

    /// Builds one .eml archive off the main actor: re-read the message from the mbox
    /// (cheap) and hand it to the archiver. Best-effort — failures are silent.
    nonisolated private static func runArchive(_ job: ArchiveJob) async {
        guard let data = try? MboxStore.readMessage(at: job.offset, length: job.length, from: job.mboxURL),
              !data.isEmpty else { return }
        await MessageArchiver.archive(rfc822: data, to: job.archiveURL)
    }

    // MARK: - Delete folder backup

    func deleteFolderBackup(for folder: MailFolder, on account: IMAPAccount) {
        guard let state = appState, let baseURL = state.backupBaseURL else { return }

        let accountDir = MboxStore.accountDir(baseDir: baseURL, account: account)
        let idxURL = MboxStore.indexURL(baseDir: baseURL, account: account, folderName: folder.name)
        let safeFolder = MboxStore.sanitize(folder.name)
        let fm = FileManager.default

        try? fm.removeItem(at: idxURL)

        // Correspondance stricte, pas un simple préfixe : « INBOX » ne doit pas emporter
        // les fichiers de « INBOX/Travail » (assaini en « INBOX_Travail ») ni de « INBOXOLD ».
        if let contents = try? fm.contentsOfDirectory(at: accountDir, includingPropertiesForKeys: nil) {
            for url in contents where MboxStore.isMbox(url.lastPathComponent, ofFolder: safeFolder) {
                try? fm.removeItem(at: url)
            }
        }

        // Self-contained .eml archives for this folder (named "<folder>_<period>_<offset>.eml")
        let archiveDir = MboxStore.archiveDir(baseDir: baseURL, account: account)
        if let contents = try? fm.contentsOfDirectory(at: archiveDir, includingPropertiesForKeys: nil) {
            for url in contents where MboxStore.isArchive(url.lastPathComponent, ofFolder: safeFolder) {
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

    /// Écriture mbox + lecture des en-têtes, exécutées hors du main actor.
    private struct WrittenMessage: Sendable {
        let offset: Int64
        let length: Int
        let from: String
        let to: String
        let cc: String
        let subject: String
        let date: Date?
        let hasAttachments: Bool
    }

    nonisolated private static func writeMessage(
        _ rfc822: Data, internalDate: String, to mboxURL: URL
    ) throws -> WrittenMessage {
        let sender = MboxStore.extractSender(from: rfc822)
        let (offset, length) = try MboxStore.appendMessage(
            messageData: rfc822, internalDate: internalDate, sender: sender, to: mboxURL
        )
        let headers = EmailParser.parseHeadersOnly(data: rfc822)
        return WrittenMessage(
            offset: offset, length: length,
            from: headers.from, to: headers.to, cc: headers.cc,
            subject: headers.subject, date: headers.date,
            hasAttachments: headers.hasAttachments
        )
    }

    /// Toujours appelé, même avec un lot vide : c'est ce qui persiste l'UIDVALIDITY
    /// d'un dossier déjà à jour, sans quoi le run suivant re-télécharge tout.
    private func flushUIDs(_ uids: Set<UInt32>, account: IMAPAccount,
                           folder: MailFolder, uidValidity: UInt32) async throws {
        let store = stateStore
        let accountID = account.id
        let folderName = folder.name
        try await Task.detached(priority: .utility) {
            try store.addUIDs(uids, accountID: accountID, folderName: folderName, uidValidity: uidValidity)
        }.value
    }

    private func save(_ entries: [EmailIndexEntry], to store: EmailIndexStore) async throws {
        try await Task.detached(priority: .utility) { try store.save(entries) }.value
    }

}

enum RestoreError: LocalizedError {
    case noData
    var errorDescription: String? { "Données du message introuvables dans le fichier mbox." }
}
