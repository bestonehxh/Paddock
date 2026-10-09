import Foundation
import Observation
import VimClient

/// One host in the sidebar: its session with ESXi, the VM list (polled every 10 s and right
/// after each action), and the sentence to show when something went wrong. Everything runs on
/// the main actor; the VimSession actor does the waiting.
@MainActor @Observable
public final class HostModel: Identifiable {
    public private(set) var info: StoredHost
    /// Internal set: tests simulate a failed poll through it.
    public internal(set) var phase: Phase = .connecting
    public private(set) var vms: [VMSummary] = []
    /// "8.0.2", for the sidebar's "5 VMs · 8.0.2" line.
    public private(set) var version = ""
    /// The last action's failure per VM (moref value), shown where it happened in muted red.
    public private(set) var actionErrors: [String: String] = [:]
    /// VMs with an action in flight (moref values); views disable their buttons.
    public private(set) var busyVMs: Set<String> = []
    /// Called after every poll, so the app can refresh the selected VM's detail.
    public var onPoll: (() -> Void)?
    /// Called when the host should be written back to hosts.json (lastSeen, thumbprint).
    var onPersist: ((StoredHost) -> Void)?
    /// Identifies the host in lists (the address never changes for a model's life).
    public let id: String

    public enum Phase: Equatable {
        case connecting
        case connected
        case failed(String)
        /// The host's certificate no longer matches the pinned one; `hash` names the pair
        /// shown in the review sheet ("SHA-1" or "SHA-256").
        case needsTrust(expected: String, actual: String, hash: String)
    }

    private var session: VimSession?
    private var pollTask: Task<Void, Never>?
    /// Bumped at the start of every poll; a poll whose number is no longer the latest throws
    /// its result away, so an older answer can't overwrite a newer one.
    private var pollGeneration = 0
    private var pollsInFlight = 0
    /// Set by `stop()`: nothing is mutated or persisted after it.
    private var stopped = false
    /// Failed polls in a row, for the back-off (10 s, 20 s, 40 s, 80 s, then 120 s).
    private var failures = 0
    /// Guest-login presence per VM moref, so views don't ask the Keychain on every redraw.
    private var guestLoginCache: [String: Bool] = [:]

    public var address: String { info.address }

    public init(info: StoredHost) {
        self.info = info
        self.id = info.address
    }

    // MARK: Lifecycle

    /// Reads the password from the Keychain, logs in, starts polling. Called once at launch or
    /// when a host is added.
    public func start() {
        guard pollTask == nil else { return }
        stopped = false
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollOnce()
                let delay = self.nextDelay()
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    public func stop() {
        stopped = true
        pollTask?.cancel()
        pollTask = nil
        let session = self.session
        self.session = nil
        if let session {
            Task { await session.logout() }
        }
    }

    /// 10 s while the host answers; doubling up to 2 minutes while it doesn't.
    private func nextDelay() -> Double {
        guard failures > 0 else { return 10 }
        return min(10 * pow(2, Double(min(failures, 4))), 120)
    }

    /// A poll out of band (right after an action). A newer poll always wins, so it's fine to
    /// start one while the loop's is still running.
    public func refreshNow() {
        Task { await self.pollOnce() }
    }

    private func makeSession() throws -> VimSession {
        if let session { return session }
        guard let password = try Keychain.password(for: Keychain.hostAccount(address: info.address)) else {
            throw LabDockError.noPassword(info.address)
        }
        let session = VimSession(host: info.address, username: info.user, password: password,
                                 expectedThumbprint: info.thumbprint, expectedThumbprintSHA256: info.thumbprintSHA256)
        self.session = session
        return session
    }

    /// One pass: the light property set for every VM plus the host's version string.
    private func pollOnce() async {
        guard !stopped else { return }
        pollGeneration += 1
        let generation = pollGeneration
        pollsInFlight += 1
        defer { pollsInFlight -= 1 }
        do {
            let session = try makeSession()
            let list = try await session.listVMs()
            guard !stopped, generation == pollGeneration else { return }
            vms = list
            // Keep the pin in step with what a successful connection actually saw: a first
            // pin for a previously unpinned host (unticked "Trust this certificate" — what the
            // Add host sheet promises), the SHA-256 half of a SHA-1-only pin, and the SHA-1
            // half after a SHA-256-only re-pin.
            if let observed = session.transport.observedThumbprint {
                var changed = false
                if let p256 = info.thumbprintSHA256, Self.sameThumbprint(p256, observed.sha256) {
                    if !Self.sameThumbprint(info.thumbprint ?? "", observed.sha1) {
                        info.thumbprint = observed.sha1
                        changed = true
                    }
                } else if info.thumbprintSHA256 == nil {
                    if info.thumbprint != nil {
                        info.thumbprintSHA256 = observed.sha256
                    } else {
                        info.thumbprint = observed.sha1
                        info.thumbprintSHA256 = observed.sha256
                    }
                    changed = true
                }
                if changed { persist() }
            }
            // The host version rarely changes: fetch the host's own properties once, not on
            // every 10-second poll (hostInfo also pulls the datastores).
            if version.isEmpty {
                let host = try await session.hostInfo()
                guard !stopped else { return }
                version = shortVersion(host.apiVersion.isEmpty ? session.transport.apiVersion : host.apiVersion)
            }
            let wasDown = phase != .connected
            phase = .connected
            failures = 0
            info.lastSeen = Date()
            if wasDown { persist() }
            onPoll?()
        } catch let error as VimError {
            guard !stopped, generation == pollGeneration else { return }
            failures += 1
            if case .certificateChanged(let expected, let actual, let hash) = error {
                phase = .needsTrust(expected: expected, actual: actual, hash: hash)
            } else {
                let wasUp = phase == .connected
                phase = .failed(sentence(for: error))
                // The moment the host stops answering is when "last seen" starts to matter.
                if wasUp { persist() }
            }
        } catch {
            guard !stopped, generation == pollGeneration else { return }
            failures += 1
            phase = .failed(error.localizedDescription)
        }
    }

    /// "8.0.2.0" → "8.0.2".
    private func shortVersion(_ v: String) -> String {
        if v.hasSuffix(".0"), v.count > 4 { String(v.dropLast(2)) } else { v }
    }

    private func sentence(for error: Error) -> String {
        (error as? VimError)?.errorDescription ?? (error as? LabDockError)?.errorDescription ?? error.localizedDescription
    }

    private func persist() {
        guard !stopped else { return }
        onPersist?(info)
    }

    // MARK: Trust

    /// Accept the certificate the host presents now, pin it, and try again. The re-pin lands
    /// in the hash the mismatch was detected in; its partner hash fills in on the next
    /// successful poll.
    public func trustNewCertificate() async {
        guard case .needsTrust(_, let actual, let hash) = phase else { return }
        if hash == "SHA-1" { info.thumbprint = actual } else { info.thumbprintSHA256 = actual }
        do {
            let session = try makeSession()
            session.transport.pin(sha1: info.thumbprint, sha256: info.thumbprintSHA256)
        } catch {
            phase = .failed(sentence(for: error))
            return
        }
        persist()
        phase = .connecting
        failures = 0
        await pollOnce()
    }

    /// Thumbprints compare with case and colons stripped (`AA:BB…` vs `AABB…`).
    private static func sameThumbprint(_ a: String, _ b: String) -> Bool {
        a.uppercased().filter(\.isHexDigit) == b.uppercased().filter(\.isHexDigit)
    }

    // MARK: Actions

    public func power(_ action: VimSession.PowerAction, vm: VMSummary) async {
        await run(vm.ref.value) { session in
            try await session.power(action, vm: vm.ref)
        }
    }

    public func takeSnapshot(name: String, description: String, memory: Bool, quiesce: Bool, vm: VMSummary) async {
        await run(vm.ref.value) { session in
            try await session.createSnapshot(vm: vm.ref, name: name, description: description, memory: memory, quiesce: quiesce)
        }
    }

    public func revert(to snapshot: MoRef, vm: VMSummary) async {
        await run(vm.ref.value) { session in
            try await session.revert(to: snapshot)
        }
    }

    public func deleteSnapshot(_ snapshot: MoRef, children: Bool, vm: VMSummary) async {
        await run(vm.ref.value) { session in
            try await session.removeSnapshot(snapshot, removeChildren: children)
        }
    }

    public func deleteAllSnapshots(vm: VMSummary) async {
        await run(vm.ref.value) { session in
            try await session.removeAllSnapshots(vm: vm.ref)
        }
    }

    public func mountTools(vm: VMSummary) async {
        await run(vm.ref.value) { session in
            try await session.mountToolsInstaller(vm: vm.ref)
        }
    }

    /// The last failed action's sentence for one VM.
    public func actionError(vm: VMSummary) -> String? { actionErrors[vm.ref.value] }
    public func clearActionError(vm: VMSummary) { actionErrors[vm.ref.value] = nil }

    /// Runs an action with the busy marker, refreshes afterwards, and records the failure
    /// sentence for that VM (cleared when its next action succeeds).
    private func run(_ key: String, _ action: (VimSession) async throws -> Void) async {
        actionErrors[key] = nil
        let session: VimSession
        do {
            session = try makeSession()
        } catch {
            actionErrors[key] = sentence(for: error)
            return
        }
        busyVMs.insert(key)
        defer { busyVMs.remove(key) }
        do {
            try await action(session)
            await pollOnce()
        } catch {
            actionErrors[key] = sentence(for: error)
        }
    }

    // MARK: Reading

    public func vm(id: String) -> VMSummary? {
        vms.first { $0.ref.value == id }
    }

    public func detail(of vm: VMSummary) async throws -> VMDetail {
        let session = try makeSession()
        return try await session.detail(of: vm.ref)
    }

    public func summary(of vm: VMSummary) async throws -> VMSummary? {
        let session = try makeSession()
        return try await session.summary(of: vm.ref)
    }

    public func consoleTicket(vm: VMSummary) async throws -> ConsoleTicket {
        let session = try makeSession()
        return try await session.consoleTicket(vm: vm.ref)
    }

    // MARK: Guest logins

    private func guestAccount(_ vm: VMSummary) -> String {
        Keychain.guestAccount(address: info.address, vm: vm.ref.value)
    }

    /// Whether a guest login is saved; cached so view bodies don't hit the Keychain every redraw.
    public func hasGuestLogin(vm: VMSummary) -> Bool {
        if let cached = guestLoginCache[vm.ref.value] { return cached }
        let has = Keychain.hasPassword(for: guestAccount(vm))
        guestLoginCache[vm.ref.value] = has
        return has
    }

    /// The saved guest login: the Keychain item holds "user\npassword" as one secret.
    public func guestLogin(vm: VMSummary) -> GuestLogin? {
        guard let secret = try? Keychain.password(for: guestAccount(vm)),
              let split = Self.splitGuestSecret(secret) else { return nil }
        return GuestLogin(username: split.user, password: split.password)
    }

    /// Splits the stored "user\npassword" secret; the password half may itself contain newlines.
    nonisolated static func splitGuestSecret(_ secret: String) -> (user: String, password: String)? {
        guard let newline = secret.firstIndex(of: "\n") else { return nil }
        return (String(secret[..<newline]), String(secret[secret.index(after: newline)...]))
    }

    /// The saved user name (for "Runs as Administrator" in the Run note).
    public func guestUser(vm: VMSummary) -> String? {
        guestLogin(vm: vm)?.username
    }

    /// Guest logins are stored as "user\npassword" under one Keychain item so the Run tab can
    /// show the user name without reading the password half separately.
    public func saveGuestLogin(user: String, password: String, vm: VMSummary) throws {
        try Keychain.setPassword(user + "\n" + password, for: guestAccount(vm))
        guestLoginCache[vm.ref.value] = true
    }

    public func removeGuestLogin(vm: VMSummary) {
        Keychain.removePassword(for: guestAccount(vm))
        guestLoginCache[vm.ref.value] = false
    }

    // MARK: Sidebar text

    /// "5 VMs · 8.0.2"; "5 VMs" while the version is still unknown.
    public var subtitle: String {
        let running = vms.filter { $0.powerState == .poweredOn }.count
        let count = vms.count == 1 ? "1 VM" : "\(vms.count) VMs"
        let head = running > 0 ? "\(count), \(running) running" : count
        return version.isEmpty ? head : "\(head) · \(version)"
    }

    /// "Couldn't reach · last seen 08:12" when the host is down.
    public var problemLine: String? {
        switch phase {
        case .connecting: nil
        case .connected: nil
        case .failed(let why): why
        case .needsTrust: "The host's certificate changed — review it to reconnect"
        }
    }

    /// "last seen 08:12" today, "last seen 2 Oct 08:12" before.
    public var lastSeenLine: String? {
        guard case .failed = phase, let seen = info.lastSeen else { return nil }
        return "last seen \(seen.formatted(Self.lastSeenFormat(for: seen)))"
    }

    nonisolated private static func lastSeenFormat(for date: Date) -> Date.FormatStyle {
        let time = Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
        return Calendar.current.isDateInToday(date) ? time : time.day().month(.abbreviated)
    }

    // MARK: Sessions for the view layer

    /// The session for guest operations run directly by a tab (files, programs).
    public func sessionForGuest() throws -> VimSession {
        try makeSession()
    }
}
