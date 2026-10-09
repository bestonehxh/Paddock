import Foundation

/// One ESXi host as it lives in `~/Library/Application Support/Paddock/hosts.json`: where to
/// reach it, who to log in as, which certificate to expect. No secrets here — passwords live in
/// the Keychain only.
public struct StoredHost: Codable, Identifiable, Hashable, Sendable {
    public var address: String
    public var user: String
    public var thumbprint: String?
    /// The same certificate's SHA-256, recorded once seen: the pin that decides from then on.
    /// Older hosts.json files don't carry it; the first successful connection fills it in.
    public var thumbprintSHA256: String?
    public var lastSeen: Date?

    public init(address: String, user: String, thumbprint: String? = nil, thumbprintSHA256: String? = nil,
                lastSeen: Date? = nil) {
        self.address = address
        self.user = user
        self.thumbprint = thumbprint
        self.thumbprintSHA256 = thumbprintSHA256
        self.lastSeen = lastSeen
    }

    public var id: String { address }
}

/// The list of hosts, as JSON. Writes are atomic (temp file + rename) so a crash can't leave a
/// half-written file. A file that exists but can't be read is an error, never an empty list:
/// the app shows the sentence and refuses to write until the user fixes or removes the file,
/// so a corrupt file can't be silently replaced by a shorter one (review, 3 Oct 2026).
public final class HostStore: Sendable {
    public let url: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directory: URL? = nil) {
        let dir = directory ?? Self.defaultDirectory
        url = dir.appendingPathComponent("hosts.json")
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("Paddock", isDirectory: true)
    }

    /// The saved hosts, sorted by address. A missing file is an empty list; anything else that
    /// goes wrong is thrown.
    public func load() throws -> [StoredHost] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw PaddockError.hostsFileUnreadable(url.path, error.localizedDescription)
        }
        if data.isEmpty { return [] }
        do {
            let hosts = try decoder.decode([StoredHost].self, from: data)
            return hosts.sorted { $0.address.localizedStandardCompare($1.address) == .orderedAscending }
        } catch {
            throw PaddockError.hostsFileUnreadable(url.path, "it isn't the JSON Paddock writes")
        }
    }

    public func save(_ hosts: [StoredHost]) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try encoder.encode(hosts)
        try data.write(to: url, options: .atomic)
        // The file carries host addresses and user names: keep it off other local users.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
