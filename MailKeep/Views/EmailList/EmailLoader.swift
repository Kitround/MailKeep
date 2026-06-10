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
    private var loadGeneration = 0          // incrémenté à chaque reload — évite les mises à jour stales
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

        // Vider uniquement si changement de dossier — sinon garder l'affichage pendant le reload
        if folderChanged || mboxURLs.isEmpty {
            allEmails = []
            visibleEmails = []
            totalCount = 0
        }

        // Rien à charger
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
                // Tâche annulée ou erreur inattendue — nettoyer
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

    private func performLoad(mboxURLs: [URL], indexURL: URL?, generation: Int) async throws {
        // Fast path : index JSON disponible et non vide
        if let idxURL = indexURL {
            let entries = await Task.detached { EmailIndexStore(indexURL: idxURL).load() }.value
            if !entries.isEmpty {
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

        // Slow path : construire l'index depuis les fichiers mbox
        let accountDir = mboxURLs.first?.deletingLastPathComponent()
        var allEntries: [EmailIndexEntry] = []

        for url in mboxURLs.reversed() {
            try Task.checkCancellation()

            let filename = url.lastPathComponent
            let ranges: [(offset: Int64, length: Int)]
            do {
                ranges = try await Task.detached { try MboxStore.messageRanges(in: url) }.value
            } catch {
                continue  // fichier illisible, on passe au suivant
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
                handle.seek(toFileOffset: UInt64(offset))
                // Force a genuine heap copy — FileHandle returns NSData-backed Data whose
                // non-zero internal offset causes rangeOfData:options:range: to overflow.
                let raw = handle.readData(ofLength: min(length, 32_768))
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
            handle.closeFile()

            allEntries.append(contentsOf: fileEntries)

            // Publier les résultats partiels (newest-first dans chaque fichier, pas encore trié global)
            let partial = allEntries
            await MainActor.run { [weak self] in
                guard let self, self.loadGeneration == generation else { return }
                self.applyEntries(partial, accountDir: accountDir)
                self.isLoading = true   // garder le spinner pendant la construction
            }
        }

        try Task.checkCancellation()

        // Sauvegarder l'index pour les prochaines ouvertures
        if let idxURL = indexURL, !allEntries.isEmpty {
            let entriesToSave = allEntries
            Task.detached { try? EmailIndexStore(indexURL: idxURL).save(entriesToSave) }
        }

        await MainActor.run { [weak self] in
            guard let self, self.loadGeneration == generation else { return }
            self.applyEntries(allEntries, accountDir: accountDir)
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
            if let dir = accountDir {
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
