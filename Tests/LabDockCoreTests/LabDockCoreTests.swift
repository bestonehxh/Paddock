import Foundation
import Testing
@testable import LabDockCore
import VimClient

/// HostStore round-trips through JSON without touching anything secret.
@Test func hostStoreRoundTrip() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("labdock-store-\(UUID().uuidString)")
    let store = HostStore(directory: dir)
    #expect(try store.load().isEmpty)
    try store.save([
        StoredHost(address: "192.0.2.4", user: "root", thumbprint: "AA:BB:CC", lastSeen: Date(timeIntervalSince1970: 1_789_000_000)),
        StoredHost(address: "10.0.0.5", user: "administrator@vsphere.local"),
    ])
    let hosts = try store.load()
    #expect(hosts.count == 2)
    #expect(hosts[0].address == "10.0.0.5")   // sorted by address
    #expect(hosts[1].thumbprint == "AA:BB:CC")
    let text = try String(contentsOf: store.url, encoding: .utf8)
    #expect(!text.contains("password"))
    try? FileManager.default.removeItem(at: dir)
}

/// Keychain account names follow the documented scheme.
@Test func keychainAccountNames() {
    #expect(Keychain.hostAccount(address: "192.0.2.4") == "host:192.0.2.4")
    #expect(Keychain.guestAccount(address: "192.0.2.4", vm: "vm-42") == "guest:192.0.2.4/vm-42")
    #expect(Keychain.service == "Bestchaan.LabDock")
}

/// Guest home folders per family.
@Test func homeFolders() {
    #expect(VimSession.homeFolder(for: .windows, login: GuestLogin(username: "DOMAIN\\alice", password: "")) == "C:\\Users\\alice")
    #expect(VimSession.homeFolder(for: .darwin, login: GuestLogin(username: "alice", password: "")) == "/Users/alice")
    #expect(VimSession.homeFolder(for: .linux, login: GuestLogin(username: "root", password: "")) == "/root")
    #expect(VimSession.homeFolder(for: .linux, login: GuestLogin(username: "alice", password: "")) == "/home/alice")
}

/// The stored guest secret splits into user and password exactly once.
@Test func guestSecretSplit() {
    let split = HostModel.splitGuestSecret("alice\ns3cret")
    #expect(split?.user == "alice")
    #expect(split?.password == "s3cret")
    let multiline = HostModel.splitGuestSecret("bob\nfirst\nsecond")
    #expect(multiline?.user == "bob")
    #expect(multiline?.password == "first\nsecond")
    #expect(HostModel.splitGuestSecret("no-newline") == nil)
}

/// The lastSeen line only appears while the host is down.
@MainActor @Test func lastSeenWording() {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("labdock-model-\(UUID().uuidString)")
    let host = HostModel(info: StoredHost(address: "10.9.9.9", user: "root", lastSeen: Date(timeIntervalSince1970: 1_789_000_000)))
    #expect(host.lastSeenLine == nil)                       // not down yet
    host.phase = .failed("Couldn't reach the host: no route")
    #expect(host.lastSeenLine?.contains("last seen") == true)
    #expect(host.problemLine == "Couldn't reach the host: no route")
    #expect(host.subtitle == "0 VMs")
    host.phase = .needsTrust(expected: "AA", actual: "BB", hash: "SHA-1")
    #expect(host.problemLine?.contains("certificate") == true)
    try? FileManager.default.removeItem(at: dir)
}


/// A hosts.json that exists but isn't LabDock's JSON is an error, not an empty list.
@Test func corruptHostsFileThrows() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("labdock-store-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = HostStore(directory: dir)
    try Data("not json".utf8).write(to: store.url)
    #expect(throws: LabDockError.self) { try store.load() }
    try? FileManager.default.removeItem(at: dir)
}

/// A hosts.json written before the SHA-256 field decodes with thumbprintSHA256 nil; the first
/// successful connection fills it in.
@Test func legacyHostsFileDecodes() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("labdock-store-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = HostStore(directory: dir)
    let legacy = """
    [{"address":"192.0.2.4","lastSeen":"2026-10-03T06:36:59Z","thumbprint":"AA:BB:CC","user":"root"}]
    """
    try Data(legacy.utf8).write(to: store.url)
    let hosts = try store.load()
    #expect(hosts.count == 1)
    #expect(hosts[0].thumbprint == "AA:BB:CC")
    #expect(hosts[0].thumbprintSHA256 == nil)
    try? FileManager.default.removeItem(at: dir)
}

/// An empty user name is handled the same way by guestUser and splitGuestSecret.
@Test func guestSecretEmptyUser() {
    let split = HostModel.splitGuestSecret("\nS3cret")
    #expect(split?.user == "")
    #expect(split?.password == "S3cret")
}
