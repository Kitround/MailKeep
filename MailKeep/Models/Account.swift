import Foundation

struct IMAPAccount: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var label: String
    var host: String
    var port: Int = 993
    var username: String
    var folders: [MailFolder] = []
    var isEnabled: Bool = true
    var schedule: BackupSchedule = BackupSchedule()
    /// Filter applied to UID SEARCH when picking which messages to back up.
    /// Default = .seen for backwards compatibility with the original behaviour.
    var messageFilter: MessageFilter = .seen

    static func new() -> IMAPAccount {
        IMAPAccount(label: "", host: "", username: "")
    }

    // Custom decoding so accounts persisted before `messageFilter` was added
    // still decode (default = .seen, the old hardcoded behaviour).
    private enum CodingKeys: String, CodingKey {
        case id, label, host, port, username, folders, isEnabled, schedule, messageFilter
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.label = try c.decode(String.self, forKey: .label)
        self.host = try c.decode(String.self, forKey: .host)
        self.port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 993
        self.username = try c.decode(String.self, forKey: .username)
        self.folders = try c.decodeIfPresent([MailFolder].self, forKey: .folders) ?? []
        self.isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        self.schedule = try c.decodeIfPresent(BackupSchedule.self, forKey: .schedule) ?? BackupSchedule()
        self.messageFilter = try c.decodeIfPresent(MessageFilter.self, forKey: .messageFilter) ?? .seen
    }

    init(id: UUID = UUID(), label: String, host: String, port: Int = 993,
         username: String, folders: [MailFolder] = [], isEnabled: Bool = true,
         schedule: BackupSchedule = BackupSchedule(),
         messageFilter: MessageFilter = .seen) {
        self.id = id
        self.label = label
        self.host = host
        self.port = port
        self.username = username
        self.folders = folders
        self.isEnabled = isEnabled
        self.schedule = schedule
        self.messageFilter = messageFilter
    }
}

enum MessageFilter: String, Codable, CaseIterable, Hashable {
    case all
    case seen
    case unseen
    case flagged

    /// IMAP search criterion (without "UID SEARCH " prefix).
    var imapCriterion: String {
        switch self {
        case .all:     return "ALL"
        case .seen:    return "SEEN"
        case .unseen:  return "UNSEEN"
        case .flagged: return "FLAGGED"
        }
    }

    var displayName: String {
        switch self {
        case .all:     return "Tous les messages"
        case .seen:    return "Lus uniquement"
        case .unseen:  return "Non lus uniquement"
        case .flagged: return "Marqués (Flagged)"
        }
    }
}

struct BackupSchedule: Codable, Hashable {
    var isEnabled: Bool = false
    var intervalMinutes: Int = 60
    var lastBackupDate: Date? = nil

    var nextBackupDate: Date? {
        guard isEnabled, let last = lastBackupDate else {
            return isEnabled ? Date() : nil
        }
        return last.addingTimeInterval(Double(intervalMinutes) * 60)
    }

    var isDue: Bool {
        guard isEnabled else { return false }
        guard let next = nextBackupDate else { return true }
        return next <= Date()
    }

    static let intervalOptions: [(label: String, minutes: Int)] = [
        ("15 minutes", 15),
        ("30 minutes", 30),
        ("1 heure", 60),
        ("6 heures", 360),
        ("12 heures", 720),
        ("24 heures", 1440),
        ("7 jours", 10080),
    ]
}
