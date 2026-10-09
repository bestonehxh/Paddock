import Foundation
import Security

/// Generic passwords in the Keychain, service `Bestchaan.LabDock`. Accounts:
/// `host:<address>` for the ESXi login, `guest:<address>/<vm moref>` for guest logins.
/// Nothing secret is ever written anywhere else.
public enum Keychain {
    public static let service = "Bestchaan.LabDock"
    /// The service before the rename to LabDock (9 Oct 2026). Its vault is read once (one prompt:
    /// a different app is asking), rewritten under `service`, then deleted.
    static let legacyService = "Bestchaan.Paddock"
    /// One Keychain item holds every secret as JSON (owner, 3 Oct 2026: the login keychain asks
    /// once per *item* per app signature, so one item per host and per guest meant a prompt for
    /// every VM; one vault item means one "Always Allow"). Older per-account items are read once
    /// and folded in.
    static let vaultAccount = "vault"

    public static func hostAccount(address: String) -> String { "host:\(address)" }
    public static func guestAccount(address: String, vm: String) -> String { "guest:\(address)/\(vm)" }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var cache: [String: String]?

    private static func query(account: String, service: String = service) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    // MARK: Vault

    /// The vault, read from the Keychain on first use (this is the one prompt).
    /// Callers hold `lock` — `mutate` keeps it across the whole read-modify-write so two
    /// concurrent changes can't write over each other's entry.
    private static func vaultLocked() throws -> [String: String] {
        if let cache { return cache }
        var entries: [String: String] = [:]
        if let data = try readItem(account: vaultAccount) {
            entries = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        } else if let data = try? readItem(account: vaultAccount, service: legacyService),
                  let old = try? JSONDecoder().decode([String: String].self, from: data) {
            // First read as LabDock: bring the Paddock vault across, then drop the old item.
            try writeVault(old)
            SecItemDelete(query(account: vaultAccount, service: legacyService) as CFDictionary)
            entries = old
        }
        // Fold in items from before the vault (they prompt once each, then are removed).
        var migrated = false
        for account in legacyAccounts() {
            if let data = try? readItem(account: account), let secret = String(data: data, encoding: .utf8) {
                if entries[account] == nil { entries[account] = secret }
                SecItemDelete(query(account: account) as CFDictionary)
                migrated = true
            }
        }
        cache = entries
        if migrated { try? writeVault(entries) }
        return entries
    }

    private static func vault() throws -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        return try vaultLocked()
    }

    private static func legacyAccounts() -> [String] {
        var q = query(account: "")
        q.removeValue(forKey: kSecAttrAccount as String)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let rows = item as? [[String: Any]] else { return [] }
        return rows.compactMap { $0[kSecAttrAccount as String] as? String }.filter { $0 != vaultAccount }
    }

    private static func readItem(account: String, service: String = service) throws -> Data? {
        var q = query(account: account, service: service)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        switch status {
        case errSecSuccess: return item as? Data
        case errSecItemNotFound: return nil
        default: throw LabDockError.keychain(status)
        }
    }

    private static func writeVault(_ entries: [String: String]) throws {
        let data = try JSONEncoder().encode(entries)
        let status = SecItemUpdate(query(account: vaultAccount) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw LabDockError.keychain(status) }
        var attributes = query(account: vaultAccount)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrLabel as String] = "LabDock (ESXi hosts and guest logins)"
        let add = SecItemAdd(attributes as CFDictionary, nil)
        guard add == errSecSuccess else { throw LabDockError.keychain(add) }
    }

    private static func mutate(_ change: (inout [String: String]) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        var entries = try vaultLocked()
        change(&entries)
        try writeVault(entries)
        cache = entries
    }

    // MARK: API (unchanged for callers)

    /// Saves or replaces a password.
    public static func setPassword(_ password: String, for account: String) throws {
        try mutate { $0[account] = password }
    }

    /// The password, nil when there is none. A Keychain that refuses (the user clicked Deny,
    /// the keychain is locked) throws, so the app can say that instead of "add the host again".
    public static func password(for account: String) throws -> String? {
        try vault()[account]
    }

    /// Whether a password exists, without a prompt once the vault has been read.
    public static func hasPassword(for account: String) -> Bool {
        (try? vault()[account]) != nil
    }

    public static func removePassword(for account: String) {
        try? mutate { $0[account] = nil }
    }

    /// The saved accounts beginning with a prefix (to clean up a removed host's guest logins).
    public static func accounts(prefix: String) -> [String] {
        ((try? vault()) ?? [:]).keys.filter { $0.hasPrefix(prefix) }.sorted()
    }
}

/// LabDock's own failures, as sentences.
public enum LabDockError: Error, LocalizedError, Sendable {
    case keychain(OSStatus)
    case noPassword(String)
    case notSelected
    case hostsFileUnreadable(String, String)
    case duplicateHost(String)
    case noCertificate

    public var errorDescription: String? {
        switch self {
        case .keychain(let status):
            switch status {
            case errSecUserCanceled, errSecAuthFailed: "The Keychain didn't let LabDock read the password; allow it when macOS asks"
            case errSecInteractionNotAllowed: "The Keychain is locked"
            default:
                "The Keychain refused (\(SecCopyErrorMessageString(status, nil).map { $0 as String } ?? "status \(status)"))"
            }
        case .noPassword(let address): "No password for \(address) in the Keychain; add the host again"
        case .notSelected: "No virtual machine is selected"
        case .hostsFileUnreadable(let path, let why): "Couldn't read \(path): \(why). Fix or remove the file, then open LabDock again"
        case .duplicateHost(let address): "\(address) is already in the list"
        case .noCertificate: "The host didn't present a certificate"
        }
    }
}
