import Foundation
import Security

/// Stores IMAP passwords in the macOS keychain (kSecClassGenericPassword).
/// Uses the default (file) keychain — the data-protection keychain requires an
/// application-identifier entitlement that ad-hoc/zip-distributed sandboxed apps
/// don't have, which silently broke saving. Migrates legacy UserDefaults entries.
struct KeychainStore {

    private static let service = "com.mailkeep.MailKeep.imap"

    private func account(for imap: IMAPAccount) -> String {
        "\(imap.username)@\(imap.host)"
    }

    private func legacyKey(for imap: IMAPAccount) -> String {
        "pwd_\(imap.username)@\(imap.host)"
    }

    private func baseQuery(for acct: String) -> [String: Any] {
        [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: acct,
        ]
    }

    func save(password: String, for imap: IMAPAccount) throws {
        let acct = account(for: imap)
        let data = Data(password.utf8)

        // Delete-then-add is the most reliable pattern — avoids the update/add
        // branching that can misbehave across keychain states.
        SecItemDelete(baseQuery(for: acct) as CFDictionary)

        var addQuery = baseQuery(for: acct)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    func load(for imap: IMAPAccount) throws -> String {
        let acct = account(for: imap)
        var query = baseQuery(for: acct)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecSuccess,
           let data = item as? Data,
           let password = String(data: data, encoding: .utf8),
           !password.isEmpty {
            return password
        }

        if status == errSecItemNotFound {
            // Migration: password stored in UserDefaults by pre-keychain builds.
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
        SecItemDelete(baseQuery(for: account(for: imap)) as CFDictionary)
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
