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

    /// Last publication time of each progress, used to rate-limit it.
    private var lastProgressPublish: [UUID: Date] = [:]
    private static let progressPublishInterval: TimeInterval = 0.2

    /// Writes progress into `AppState` — at most 5 times a second.
    ///
    /// `activeProgress` is `@Published`: every write invalidates everything observing it.
    /// Written once per message (dozens per second), it drove macOS menu updates — which
    /// are synchronous and re-entrant — to call themselves endlessly:
    /// `menuNeedsUpdate → render → menuNeedsUpdate → …` until the stack overflowed
    /// (SIGSEGV on the stack guard).
    ///
    /// `force` for phase transitions and terminal states, which must show immediately.
    private func publish(_ progress: BackupProgress, force: Bool = false) {
        guard let state = appState else { return }
        let now = Date()
        if !force, let last = lastProgressPublish[progress.id],
           now.timeIntervalSince(last) < Self.progressPublishInterval {
            return
        }
        lastProgressPublish[progress.id] = now
        state.activeProgress[progress.id] = progress
    }

    private func clearProgress(_ id: UUID) {
        lastProgressPublish.removeValue(forKey: id)
        appState?.activeProgress.removeValue(forKey: id)
    }

    /// A pending .eml archive: re-read the message from the mbox we just wrote
    /// (tiny footprint) and build the archive off the critical download path.
    private struct ArchiveJob: Sendable {
        let mboxURL: URL
        let offset: Int64
        let length: Int
        let archiveURL: URL
    }

    // MARK: - Public API

    /// Runs enabled accounts in parallel, but their folders one after another: each folder
    /// opens its own IMAP connection and servers cap how many an account may hold at once
    /// (Posteo ~10, Gmail 15).
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
        // lastBackupDate only if at least one folder succeeded — a scheduled backup that
        // fails (server down, bad password) is retried on the next tick.
        guard let state = appState else { return }
        for account in state.accounts where succeededAccounts.contains(account.id) {
            var updated = account
            updated.schedule.lastBackupDate = Date()
            state.updateAccount(updated)
        }
    }

    /// Runs an account's folders one after another — a single IMAP connection open to
    /// that server at a time.
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

        // The same folder can be started from the menu bar, the window, ⌘⇧B and the
        // scheduler. Two concurrent runs wrote the same .mbox and the same JSON index in
        // parallel — corrupted index and duplicated messages.
        let alreadyRunning = state.activeProgress.values.contains {
            $0.accountID == account.id && $0.folderName == folder.name
        }
        guard !alreadyRunning else { return false }

        // A Stop requested outside the loop (during connect, the final flush, or on a run
        // that failed) stayed armed and stopped the next run on its first message.
        stopRequested.remove(stopKey(account.id, folder.name))

        var progress = BackupProgress(
            accountID: account.id,
            accountLabel: account.label,
            folderName: folder.name
        )
        let progressID = progress.id
        publish(progress, force: true)

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
            publish(progress, force: true)
            try await client.connect(host: account.host, port: account.port)

            progress.phase = .authenticating
            publish(progress, force: true)
            try await client.login(username: account.username, password: password)

            progress.phase = .selectingFolder
            publish(progress, force: true)
            let folderStatus = try await client.selectFolder(folder.name)

            // UID validity check — if the server reassigned UIDs, wipe and start over
            var folderState = stateStore.load(accountID: account.id, folderName: folder.name)
            if let existing = folderState,
               existing.uidValidity != folderStatus.uidValidity,
               folderStatus.uidValidity != 0 {
                stateStore.wipe(accountID: account.id, folderName: folder.name)
                folderState = nil
            }

            progress.phase = .fetchingUIDList
            publish(progress, force: true)

            // Fetch the UIDs matching the account's filter (SEEN by default, for
            // backwards compatibility), then filter locally against knownUIDs. UID SEARCH
            // downloads no messages — just a list of UIDs, fast even over 20 000 of them.
            let knownUIDs = folderState?.backedUpUIDs ?? []
            let serverUIDs = try await client.fetchAllUIDs(filter: account.messageFilter)
            let toFetch = serverUIDs.filter { !knownUIDs.contains($0) }

            progress.total = toFetch.count
            progress.phase = .downloadingMessages
            publish(progress, force: true)

            var downloadedUIDs: Set<UInt32> = []
            var bytesWritten: Int64 = 0
            let idxURL = MboxStore.indexURL(baseDir: baseURL, account: account, folderName: folder.name)
            let indexStore = EmailIndexStore(indexURL: idxURL)
            // Index held in memory for the whole run — the old append() re-read and
            // rewrote the entire JSON on every flush (O(n²) on large folders).
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
                publish(progress)

                let msg = try await fetchWithRetry(uid: uid, getClient: { client }, reconnect: reconnect)

                let (year, month) = MboxStore.yearMonth(fromInternalDate: msg.internalDate)
                let mboxURL = MboxStore.mboxURL(
                    baseDir: baseURL, account: account,
                    folderName: folder.name, year: year, month: month
                )
                // mbox write + header parsing off the main actor: on a message with large
                // attachments, doing them here froze the interface.
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

            // Remaining flush
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
                publish(progress, force: true)

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
                        publish(progress)
                        // Stop respected between launches; in-flight archives finish.
                        // Tested, not consumed: `remove` cleared the flag on the first
                        // pass, so every later pass saw no stop and kept launching jobs —
                        // a Stop during archiving only ever skipped one. The flag is
                        // cleared at the start of the next run.
                        if !stopRequested.contains(key), let job = jobIterator.next() {
                            group.addTask { await BackupEngine.runArchive(job) }
                            inFlight += 1
                        }
                    }
                }
            }

            if wasStopped {
                progress.phase = .stopped
                publish(progress, force: true)
                run.finishedAt = Date()
                run.messagesDownloaded = progress.current
                run.messagesSkipped = folderState?.backedUpUIDs.count ?? 0
                run.bytesWritten = bytesWritten
                run.wasStopped = true
                state.updateRun(run)
            } else {
                progress.phase = .done
                publish(progress, force: true)
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
            publish(progress, force: true)
            run.finishedAt = Date()
            run.errorMessage = error.localizedDescription
            state.updateRun(run)
        }

        try? await Task.sleep(for: .seconds(2))
        clearProgress(progressID)
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
        guard appState != nil else { return }

        var progress = BackupProgress(
            accountID: account.id,
            accountLabel: account.label,
            folderName: "Import → \(folder.displayName)"
        )
        progress.phase = .importing
        progress.total = urls.count
        let progressID = progress.id
        publish(progress, force: true)

        let destDir = MboxStore.accountDir(baseDir: baseURL, account: account)
        let idxURL = MboxStore.indexURL(baseDir: baseURL, account: account, folderName: folder.name)

        do {
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        } catch {
            progress.phase = .failed
            progress.errorMessage = error.localizedDescription
            publish(progress, force: true)
            try? await Task.sleep(for: .seconds(2))
            clearProgress(progressID)
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
            publish(progress, force: true)

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

        // The index is only dropped when something actually landed: it rebuilds on the
        // next folder open, but an import that failed outright has no reason to make the
        // user pay for that full pass.
        if importedCount > 0 {
            try? FileManager.default.removeItem(at: idxURL)
        }

        if errorMessages.isEmpty {
            progress.phase = .done
        } else {
            progress.phase = importedCount > 0 ? .done : .failed
            progress.errorMessage = errorMessages.joined(separator: "\n")
        }
        publish(progress, force: true)

        try? await Task.sleep(for: .seconds(2))
        clearProgress(progressID)
    }

    // MARK: - Restore

    func restoreFolder(from mboxURL: URL, to folder: MailFolder, on account: IMAPAccount) async {
        guard appState != nil else { return }

        var progress = BackupProgress(
            accountID: account.id,
            accountLabel: account.label,
            folderName: "Restauration → \(folder.displayName)"
        )
        let progressID = progress.id
        publish(progress, force: true)

        do {
            // Offsets only: content is re-read one message at a time, a multi-gigabyte
            // mbox must never sit in memory as a single block.
            let ranges = try await Task.detached { try MboxStore.messageRanges(in: mboxURL) }.value
            progress.total = ranges.count
            publish(progress, force: true)

            let client = IMAPClient()
            progress.phase = .connecting
            publish(progress, force: true)
            try await client.connect(host: account.host, port: account.port)
            progress.phase = .authenticating
            publish(progress, force: true)
            let password = try keychain.load(for: account)
            try await client.login(username: account.username, password: password)

            progress.phase = .downloadingMessages
            // One message refused by the server must not abort the whole restore.
            // Consecutive failures (dead connection) do make it give up.
            var failedCount = 0
            var consecutiveFailures = 0
            for (i, range) in ranges.enumerated() {
                progress.current = i + 1
                publish(progress)
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

            // `try?`: every message is already on the server by this point. A failing
            // LOGOUT (server dropping the connection right after) flipped a fully
            // successful restore to "failed".
            try? await client.logout()
            progress.phase = .done
            if failedCount > 0 {
                progress.errorMessage = "\(failedCount) message(s) refusé(s) par le serveur."
            }
            publish(progress, force: true)

        } catch {
            progress.phase = .failed
            progress.errorMessage = error.localizedDescription
            publish(progress, force: true)
        }

        try? await Task.sleep(for: .seconds(2))
        clearProgress(progressID)
    }

    func restoreMessage(_ email: EmailMessage, to folder: MailFolder, on account: IMAPAccount) async {
        guard appState != nil else { return }

        var progress = BackupProgress(
            accountID: account.id,
            accountLabel: account.label,
            folderName: "Restauration → \(folder.displayName)"
        )
        progress.total = 1
        let progressID = progress.id
        publish(progress, force: true)

        do {
            let data: Data
            if let url = email.mboxFileURL, email.mboxLength > 0 {
                let offset = email.mboxOffset, length = email.mboxLength
                data = try await Task.detached {
                    try MboxStore.readMessage(at: offset, length: length, from: url)
                }.value
            } else if let raw = email.rawData {
                data = raw
            } else {
                throw RestoreError.noData
            }

            let client = IMAPClient()
            progress.phase = .connecting
            publish(progress, force: true)
            try await client.connect(host: account.host, port: account.port)

            progress.phase = .authenticating
            publish(progress, force: true)
            let password = try keychain.load(for: account)
            try await client.login(username: account.username, password: password)

            progress.phase = .downloadingMessages
            progress.current = 1
            publish(progress, force: true)
            let internalDate = email.date.map { MboxStore.imapDate(from: $0) }
            try await client.appendMessage(to: folder.name, data: data, internalDate: internalDate)

            try? await client.logout()
            progress.phase = .done
            publish(progress, force: true)

        } catch {
            progress.phase = .failed
            progress.errorMessage = error.localizedDescription
            publish(progress, force: true)
        }

        try? await Task.sleep(for: .seconds(2))
        clearProgress(progressID)
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

        // Strict match, not a bare prefix: "INBOX" must not carry off the files of
        // "INBOX/Travail" (sanitised to "INBOX_Travail") nor those of "INBOXOLD".
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

    /// mbox write + header read, both executed off the main actor.
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

    /// Always called, even with an empty batch: this is what persists the UIDVALIDITY of
    /// an already up-to-date folder, without which the next run re-downloads everything.
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
