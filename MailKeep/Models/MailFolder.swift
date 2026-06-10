import Foundation

struct MailFolder: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var displayName: String
    var isEnabled: Bool = true

    init(name: String) {
        self.name = name
        self.displayName = MailFolder.makeDisplayName(name)
    }

    private static func makeDisplayName(_ name: String) -> String {
        let knownNames: [String: String] = [
            "INBOX": "Boîte de réception",
            "Sent": "Envoyés",
            "Sent Messages": "Envoyés",
            "Drafts": "Brouillons",
            "Trash": "Corbeille",
            "Deleted Messages": "Corbeille",
            "Junk": "Indésirables",
            "Spam": "Indésirables",
            "Archive": "Archives",
            "Archives": "Archives",
        ]
        return knownNames[name] ?? name.components(separatedBy: "/").last ?? name
    }
}
