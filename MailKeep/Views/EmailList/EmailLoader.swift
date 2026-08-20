import Foundation

@MainActor
final class EmailLoader: ObservableObject {
    @Published var visibleEmails: [EmailMessage] = []
    @Published var isLoading = false
    @Published var totalCount = 0
    @Published var error: String? = nil
    @Published var searchQuery: String = ""

    private var allEmails: [EmailMessage] = []
    private static let pageSize = 50
    private var visibleCount = EmailLoader.pageSize

    var hasMore: Bool { searchQuery.isEmpty && visibleCount < allEmails.count }
    var isSearching: Bool { !searchQuery.isEmpty }

    private var loadedURLs: [URL] = []
    private var loadGeneration = 0          // bumped on every reload — keeps stale updates out
    private var loadTask: Task<Void, Never>? = nil
    private var searchTask: Task<Void, Never>? = nil

    // MARK: - Public API

    func load(mboxURLs: [URL], indexURL: URL?) {
        guard mboxURLs != loadedURLs else { return }
        reload(mboxURLs: mboxURLs, indexURL: indexURL)
    }

    func reload(mboxURLs: [URL], indexURL: URL?) {
        loadTask?.cancel()
        loadTask = nil

        let folderChanged = mboxURLs.first?.deletingLastPathComponent()
            != loadedURLs.first?.deletingLastPathComponent()

        loadedURLs = mboxURLs
        searchQuery = ""
        visibleCount = EmailLoader.pageSize
        error = nil

        // Clear only when the folder changed — otherwise keep what is on screen during the reload
        if folderChanged || mboxURLs.isEmpty {
            allEmails = []
            visibleEmails = []
            totalCount = 0
        }

        // Nothing to load
        guard !mboxURLs.isEmpty else {
            isLoading = false
            return
        }

        isLoading = true
        loadGeneration += 1
        let generation = loadGeneration

        loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try await self?.performLoad(
                    mboxURLs: mboxURLs,
                    indexURL: indexURL,
                    generation: generation
                )
            } catch {
                // Cancelled task or unexpected error — clean up
                await MainActor.run { [weak self] in
                    guard let self, self.loadGeneration == generation else { return }
                    if !(error is CancellationError) {
                        self.error = error.localizedDescription
                    }
                    self.isLoading = false
                }
            }
        }
    }

    // MARK: - Pagination

    func loadMore() {
        guard hasMore else { return }
        visibleCount = min(visibleCount + Self.pageSize, allEmails.count)
        updateVisible()
    }

    // MARK: - Search

    func applySearch(_ query: String) {
        searchQuery = query
        searchTask?.cancel()
        guard !query.isEmpty else {
            visibleCount = Self.pageSize
            updateVisible()
            return
        }
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            self.updateVisible()
        }
    }

    // MARK: - Body resolution

    /// Returns the cached parsed message immediately if available, otherwise parses on a
    /// background thread and updates caches. The optional callback fires on the main actor
    /// once parsing completes (only invoked when a real parse happened).
    func resolveBody(for email: EmailMessage, onParsed: ((EmailMessage) -> Void)? = nil) -> EmailMessage {
        let bodyAlreadyLoaded = email.bodyHTML != nil || email.bodyText != nil
        let attachmentsAlreadyLoaded = !email.hasAttachments || !email.attachments.isEmpty
        if bodyAlreadyLoaded && attachmentsAlreadyLoaded { return email }

        // Parse off the main thread — large MIME trees + base64 attachments can take
        // hundreds of ms and freeze the UI when invoked synchronously from a tap.
        let snapshot = email
        Task.detached(priority: .userInitiated) { [weak self] in
            var working = snapshot
            EmailParser.parseBody(into: &working)
            let parsed = working
            let loader = self
            await MainActor.run {
                guard let loader else { return }
                if let idx = loader.allEmails.firstIndex(where: { $0.id == parsed.id }) {
                    loader.allEmails[idx] = parsed
                }
                if let idx = loader.visibleEmails.firstIndex(where: { $0.id == parsed.id }) {
                    loader.visibleEmails[idx] = parsed
                }
                onParsed?(parsed)
            }
        }
        return email
    }

    // MARK: - Core load logic

    /// `nonisolated`: without it the method inherited the class's `@MainActor` isolation,
    /// and the whole index rebuild — opening files, seek/read per message, header parsing —
    /// ran on the main actor, freezing the interface for as long as the folder took to walk.
    /// Every access to `self` already goes through `MainActor.run`.
    nonisolated private func performLoad(mboxURLs: [URL], indexURL: URL?, generation: Int) async throws {
        // Fast path: a JSON index that exists, is not empty, and still covers the files
        if let idxURL = indexURL {
            let entries = await Task.detached { EmailIndexStore(indexURL: idxURL).load() }.value
            if !entries.isEmpty, Self.indexCovers(mboxURLs, entries: entries) {
                try Task.checkCancellation()
                let dir = mboxURLs.first?.deletingLastPathComponent()
                await MainActor.run { [weak self] in
                    guard let self, self.loadGeneration == generation else { return }
                    self.applyEntries(entries, accountDir: dir)
                }
                return
            }
        }

        try Task.checkCancellation()

        // Slow path: build the index from the mbox files
        let accountDir = mboxURLs.first?.deletingLastPathComponent()
        var allEntries: [EmailIndexEntry] = []

        for url in mboxURLs.reversed() {
            try Task.checkCancellation()

            let filename = url.lastPathComponent
            let ranges: [(offset: Int64, length: Int)]
            do {
                ranges = try await Task.detached { try MboxStore.messageRanges(in: url) }.value
            } catch {
                continue  // unreadable file, move on to the next
            }
            guard !ranges.isEmpty else { continue }

            var fileEntries: [EmailIndexEntry] = []
            let handle: FileHandle
            do {
                handle = try FileHandle(forReadingFrom: url)
            } catch {
                continue
            }

            for (offset, length) in ranges.reversed() {
                if Task.isCancelled { break }
                guard (try? handle.seek(toOffset: UInt64(offset))) != nil else { continue }
                // Force a genuine heap copy — FileHandle returns NSData-backed Data whose
                // non-zero internal offset causes rangeOfData:options:range: to overflow.
                let raw = ((try? handle.read(upToCount: min(length, 32_768))).flatMap { $0 }) ?? Data()
                let block = raw.withUnsafeBytes { src in
                    src.count > 0 ? Data(bytes: src.baseAddress!, count: src.count) : Data()
                }
                let msg = EmailParser.parseHeadersOnly(mboxBlock: block)
                fileEntries.append(EmailIndexEntry(
                    id: UUID(),
                    from: msg.from, to: msg.to, cc: msg.cc,
                    subject: msg.subject, date: msg.date,
                    filename: filename,
                    offset: offset, length: length,
                    hasAttachments: msg.hasAttachments
                ))
            }
            try? handle.close()

            allEntries.append(contentsOf: fileEntries)

            // Publish partial results (newest-first within each file, not yet sorted globally)
            let partial = allEntries
            await MainActor.run { [weak self] in
                guard let self, self.loadGeneration == generation else { return }
                self.applyEntries(partial, accountDir: accountDir)
                self.isLoading = true   // garder le spinner pendant la construction
            }
        }

        try Task.checkCancellation()

        // Save the index for the next time the folder is opened
        if let idxURL = indexURL, !allEntries.isEmpty {
            let entriesToSave = allEntries
            Task.detached { try? EmailIndexStore(indexURL: idxURL).save(entriesToSave) }
        }

        // Local copy before crossing to the main actor, like the two other publications:
        // capturing the `var` itself is a data race in Swift 6.
        let finalEntries = allEntries
        await MainActor.run { [weak self] in
            guard let self, self.loadGeneration == generation else { return }
            self.applyEntries(finalEntries, accountDir: accountDir)
        }
    }

    // MARK: - Private

    private func applyEntries(_ entries: [EmailIndexEntry], accountDir: URL?) {
        allEmails = entries.map { entry in
            var msg = EmailMessage()
            msg.id = entry.id
            msg.from = entry.from
            msg.to = entry.to
            msg.cc = entry.cc
            msg.subject = entry.subject
            msg.date = entry.date
            // The filename is read back from the index file on disk, so it is treated as
            // data, not as a trusted path: a separator or ".." in it would point the reader
            // outside the account's own directory.
            if let dir = accountDir, Self.isPlainFilename(entry.filename) {
                msg.mboxFileURL = dir.appendingPathComponent(entry.filename)
            }
            msg.mboxOffset = entry.offset
            msg.mboxLength = entry.length
            msg.hasAttachments = entry.hasAttachments
            return msg
        }
        allEmails.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        totalCount = allEmails.count
        updateVisible()
        isLoading = false
    }

    /// True when every mbox file is described by the index all the way to its last byte.
    ///
    /// The two things a backup writes are flushed at different rates: UIDs every 50
    /// messages, the index every 250. A run cut short — crash, force quit, power loss —
    /// therefore leaves a window where messages sit in the mbox, the UID state counts them
    /// as downloaded so no later run fetches them again, and the index never heard of them.
    /// The fast path trusted any non-empty index, so those messages stayed invisible for
    /// good. One `stat` per file against the furthest byte its entries reach sends a
    /// short index back through the rebuild instead — which also picks up an mbox grown by
    /// something other than this app.
    nonisolated static func indexCovers(_ mboxURLs: [URL], entries: [EmailIndexEntry]) -> Bool {
        var reach: [String: Int64] = [:]
        for entry in entries {
            let end = entry.offset + Int64(entry.length)
            if end > reach[entry.filename] ?? 0 { reach[entry.filename] = end }
        }
        for url in mboxURLs {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            guard size > 0 else { continue }   // an empty file has nothing to describe
            // One byte of slack: a rebuilt index stops at the \n before the next "From ",
            // a backup-written one includes it.
            guard let covered = reach[url.lastPathComponent], size <= covered + 1 else { return false }
        }
        return true
    }

    /// A single path component, and not a way back up the tree.
    nonisolated private static func isPlainFilename(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.contains("\\") && name != "." && name != ".."
    }

    private func updateVisible() {
        if searchQuery.isEmpty {
            visibleEmails = Array(allEmails.prefix(visibleCount))
        } else {
            let q = searchQuery.lowercased()
            visibleEmails = allEmails.filter {
                $0.from.lowercased().contains(q) ||
                $0.subject.lowercased().contains(q) ||
                $0.to.lowercased().contains(q)
            }
        }
    }
}
