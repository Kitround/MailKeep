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

    /// kSecAttrAccessible is only honoured by the data-protection keychain — without
    /// kSecUseDataProtectionKeychain the item lands in the legacy file keychain where
    /// the accessibility attribute is silently ignored.
    private func baseQuery(for acct: String, dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: acct,
        ]
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    func save(password: String, for imap: IMAPAccount) throws {
        let acct = account(for: imap)
        let data = Data(password.utf8)
        do {
            try saveItem(data, account: acct, dataProtection: true)
        } catch KeychainError.saveFailed(let status) where status == errSecMissingEntitlement {
            // Unsigned/dev builds can lack data-protection access — fall back to file keychain.
            try saveItem(data, account: acct, dataProtection: false)
        }
    }

    private func saveItem(_ data: Data, account acct: String, dataProtection: Bool) throws {
        let query = baseQuery(for: acct, dataProtection: dataProtection)
        var attributes: [String: Any] = [kSecValueData as String: data]
        if dataProtection {
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        }

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }

        if updateStatus == errSecItemNotFound {
            var addQuery = query
            for (k, v) in attributes { addQuery[k] = v }
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

        if let password = loadItem(account: acct, dataProtection: true) {
            return password
        }
        // Migration: item stored in the legacy file keychain (pre data-protection builds)
        if let password = loadItem(account: acct, dataProtection: false) {
            try? saveItem(Data(password.utf8), account: acct, dataProtection: true)
            SecItemDelete(baseQuery(for: acct, dataProtection: false) as CFDictionary)
            return password
        }
        // Migration: password stored in UserDefaults (pre keychain builds)
        let key = legacyKey(for: imap)
        if let legacy = UserDefaults.standard.string(forKey: key), !legacy.isEmpty {
            try? save(password: legacy, for: imap)
            UserDefaults.standard.removeObject(forKey: key)
            return legacy
        }
        throw KeychainError.notFound
    }

    private func loadItem(account acct: String, dataProtection: Bool) -> String? {
        var query = baseQuery(for: acct, dataProtection: dataProtection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let password = String(data: data, encoding: .utf8),
              !password.isEmpty else { return nil }
        return password
    }

    func delete(for imap: IMAPAccount) {
        let acct = account(for: imap)
        SecItemDelete(baseQuery(for: acct, dataProtection: true) as CFDictionary)
        SecItemDelete(baseQuery(for: acct, dataProtection: false) as CFDictionary)
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
