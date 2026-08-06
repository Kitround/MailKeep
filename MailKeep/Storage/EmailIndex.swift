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

}
