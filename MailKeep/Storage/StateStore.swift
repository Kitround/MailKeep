import Foundation

struct FolderState: Codable {
    var uidValidity: UInt32
    var backedUpUIDs: Set<UInt32>
    var lastUidNext: UInt32?   // uidNext connu après le dernier backup
}

struct StateStore {
    private let baseURL: URL

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        baseURL = appSupport.appendingPathComponent("MailKeep/state", isDirectory: true)
        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    }

    func load(accountID: UUID, folderName: String) -> FolderState? {
        let url = stateURL(accountID: accountID, folderName: folderName)
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(FolderState.self, from: data) else {
            return nil
        }
        return state
    }

    func save(_ state: FolderState, accountID: UUID, folderName: String) throws {
        let url = stateURL(accountID: accountID, folderName: folderName)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(state)
        try data.write(to: url, options: .atomic)
    }

    func addUIDs(_ uids: Set<UInt32>, accountID: UUID, folderName: String, uidValidity: UInt32, uidNext: UInt32? = nil) throws {
        var state = load(accountID: accountID, folderName: folderName) ?? FolderState(uidValidity: uidValidity, backedUpUIDs: [])
        state.backedUpUIDs.formUnion(uids)
        if let next = uidNext { state.lastUidNext = next }
        try save(state, accountID: accountID, folderName: folderName)
    }

    func wipe(accountID: UUID, folderName: String) {
        let url = stateURL(accountID: accountID, folderName: folderName)
        try? FileManager.default.removeItem(at: url)
    }

    func wipeAccount(accountID: UUID) {
        let accountDir = baseURL.appendingPathComponent(accountID.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: accountDir)
    }

    func wipeAll() {
        try? FileManager.default.removeItem(at: baseURL)
        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    }

    func cacheSize() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: baseURL, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    private func stateURL(accountID: UUID, folderName: String) -> URL {
        let safe = folderName
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        let accountDir = baseURL.appendingPathComponent(accountID.uuidString, isDirectory: true)
        return accountDir.appendingPathComponent("\(safe).json")
    }
}
