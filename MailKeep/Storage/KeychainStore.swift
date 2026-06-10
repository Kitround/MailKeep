import Foundation
import Security

/// Stores IMAP passwords in the macOS Keychain (kSecClassGenericPassword).
/// Migrates legacy UserDefaults entries on first read.
struct KeychainStore {

    private static let service = "com.mailkeep.MailKeep.imap"

    private func account(for imap: IMAPAccount) -> String {
        "\(imap.username)@\(imap.host)"
    }

    private func legacyKey(for imap: IMAPAccount) -> String {
        "pwd_\(imap.username)@\(imap.host)"
    }

    func save(password: String, for imap: IMAPAccount) throws {
        let acct = account(for: imap)
        let data = Data(password.utf8)

        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: acct,
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }

        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.saveFailed(addStatus)
            }
            return
        }

        throw KeychainError.saveFailed(updateStatus)
    }

    func load(for imap: IMAPAccount) throws -> String {
        let acct = account(for: imap)
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: acct,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecSuccess,
           let data = item as? Data,
           let password = String(data: data, encoding: .utf8),
           !password.isEmpty {
            return password
        }

        if status == errSecItemNotFound {
            // Legacy migration: pull from UserDefaults if present, then move into Keychain.
            let key = legacyKey(for: imap)
            if let legacy = UserDefaults.standard.string(forKey: key), !legacy.isEmpty {
                try? save(password: legacy, for: imap)
                UserDefaults.standard.removeObject(forKey: key)
                return legacy
            }
            throw KeychainError.notFound
        }

        throw KeychainError.loadFailed(status)
    }

    func delete(for imap: IMAPAccount) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account(for: imap),
        ]
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: legacyKey(for: imap))
    }
}

enum KeychainError: LocalizedError {
    case notFound
    case saveFailed(OSStatus)
    case loadFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "Mot de passe non trouvé — veuillez le saisir à nouveau."
        case .saveFailed(let status):
            return "Échec de l'enregistrement du mot de passe (Keychain \(status))."
        case .loadFailed(let status):
            return "Échec de la lecture du mot de passe (Keychain \(status))."
        }
    }
}
