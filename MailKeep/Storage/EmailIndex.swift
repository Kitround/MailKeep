import Foundation

// MARK: - Index entry

struct EmailIndexEntry: Codable, Identifiable {
    var id: UUID
    var from: String
    var to: String
    var cc: String
    var subject: String
    var date: Date?
    var filename: String        // e.g. "INBOX_2024-03.mbox"
    var offset: Int64           // byte offset of message block in mbox file (at 'F' of "From " line)
    var length: Int             // byte length of message block in mbox file
    var hasAttachments: Bool = false
}

// MARK: - Index store

struct EmailIndexStore {
    let url: URL

    init(indexURL: URL) {
        self.url = indexURL
    }

    var exists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: Read / Write

    func load() -> [EmailIndexEntry] {
        guard let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([EmailIndexEntry].self, from: data) else {
            return []
        }
        return entries
    }

    func save(_ entries: [EmailIndexEntry]) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(entries).write(to: url, options: .atomic)
    }

    func wipe() {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Build from mbox files

    /// Scans mbox files and builds an index. Returns sorted entries (newest first).
    func build(from mboxURLs: [URL]) throws -> [EmailIndexEntry] {
        var entries: [EmailIndexEntry] = []

        for url in mboxURLs {
            let filename = url.lastPathComponent
            let ranges = try MboxStore.messageRanges(in: url)
            guard !ranges.isEmpty else { continue }
            let handle = try FileHandle(forReadingFrom: url)
            defer { handle.closeFile() }

            for (offset, length) in ranges {
                handle.seek(toFileOffset: UInt64(offset))
                // Force a genuine heap copy — FileHandle returns NSData-backed Data whose
                // non-zero internal offset causes rangeOfData:options:range: to overflow.
                let raw = handle.readData(ofLength: min(length, 32_768))
                let block = raw.withUnsafeBytes { src in
                    src.count > 0 ? Data(bytes: src.baseAddress!, count: src.count) : Data()
                }
                let msg = EmailParser.parseHeadersOnly(mboxBlock: block)
                entries.append(EmailIndexEntry(
                    id: UUID(),
                    from: msg.from,
                    to: msg.to,
                    cc: msg.cc,
                    subject: msg.subject,
                    date: msg.date,
                    filename: filename,
                    offset: offset,
                    length: length,
                    hasAttachments: msg.hasAttachments
                ))
            }
        }
        return entries
    }
}
