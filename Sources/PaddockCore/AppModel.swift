import AppKit
import Foundation
import Observation
import VimClient

/// What the Add host sheet learns about a host before it's saved.
public struct HostProbe: Sendable {
    public var product: String       // "VMware ESXi 8.0.2 build-…"
    public var version: String       // "8.0.2"
    public var thumbprintSHA1: String
    public var thumbprintSHA256: String
    public var certificateSubject: String?
}

/// The app's whole state: the hosts (each with its polling model), what's selected, the
/// selected VM's heavy detail. UI-language sentences for everything that can go wrong.
@MainActor @Observable
public final class AppModel {
    public private(set) var hosts: [HostModel] = []
    public var selection: Selection?
    public private(set) var detail: VMDetail?
    public private(set) var detailRunning = false
    /// Why the selected VM's detail couldn't be fetched, for the Overview to show.
    public private(set) var detailError: String?
    /// hosts.json couldn't be read: shown in the sidebar; nothing is written until it's fixed.
    public private(set) var storeError: String?
    /// ⌘\ hides the sidebar so the console fills the window.
    public var sidebarVisible = true
    /// Dragging the sidebar's edge widens it for long VM names (220…420 pt, remembered).
    public var sidebarWidth: CGFloat = max(220, min(420, CGFloat(UserDefaults.standard.double(forKey: "sidebarWidth")))) {
        didSet { UserDefaults.standard.set(Double(sidebarWidth), forKey: "sidebarWidth") }
    }
    /// Sidebar filter: which VMs to list.
    public var filter: VMFilter = .all
    /// Bumped by a double-click on a VM row: the detail switches to the Console tab.
    public var consoleRequest = 0
    /// The window is in macOS full screen: no traffic lights, so the sidebar and the bar move up.
    public var windowFullScreen = false

    // MARK: Console (the "Keys ▾" menu in the bar talks to the console page through these)

    public enum ConsoleCommand: String, Sendable, CaseIterable {
        case ctrlAltDel, pasteIntoConsole, sendClipboard, windowsKey, ctrlEsc, altTab, ctrlShiftEsc, zoomFit, zoomActual, reconnect, resizeNow
    }
    public struct ConsoleRequest: Equatable, Sendable {
        public var serial: Int
        public var command: ConsoleCommand
    }
    /// The last command asked for; the console page acts on each new serial.
    public private(set) var consoleCommandRequest: ConsoleRequest?
    public func requestConsole(_ command: ConsoleCommand) {
        consoleCommandRequest = ConsoleRequest(serial: (consoleCommandRequest?.serial ?? 0) + 1, command: command)
    }

    /// What the console page reports back, for the menu to show.
    public struct ConsoleStatus: Equatable, Sendable {
        public var size: String?        // "1,024 × 768"
        public var fps: Int
        public var state: String        // "connected", "connecting…", "disconnected"
        public var connected: Bool
        public var zoomFit: Bool
        public var note: String?        // the last thing an action said
        public init(size: String? = nil, fps: Int = 0, state: String = "", connected: Bool = false, zoomFit: Bool = true, note: String? = nil) {
            self.size = size; self.fps = fps; self.state = state; self.connected = connected; self.zoomFit = zoomFit; self.note = note
        }
    }
    public var consoleStatus = ConsoleStatus()
    /// Fit mode asks the guest (through Tools) to match the window; off keeps the guest's size.
    /// Opt-in and remembered: a resize on every console open is suspected of waking Windows to
    /// its lock screen (owner, 3 Oct 2026).
    public var consoleFollowsWindow = UserDefaults.standard.bool(forKey: "consoleFollowsWindow") {
        didSet { UserDefaults.standard.set(consoleFollowsWindow, forKey: "consoleFollowsWindow") }
    }
    /// Two-way clipboard sharing through Tools while a console is open (needs a guest login).
    public var clipboardSharing = true
    /// Rewind records console frames only when asked (owner, 3 Oct 2026: on by default is
    /// wasteful). Remembered across launches.
    public var consoleRewind = UserDefaults.standard.bool(forKey: "consoleRewind") {
        didSet { UserDefaults.standard.set(consoleRewind, forKey: "consoleRewind") }
    }

    public enum VMFilter: String, CaseIterable, Sendable {
        case all, running, off
        public var title: String {
            switch self {
            case .all: "All"
            case .running: "Running"
            case .off: "Off"
            }
        }
        public func matches(_ vm: VMSummary) -> Bool {
            switch self {
            case .all: true
            case .running: vm.powerState == .poweredOn
            case .off: vm.powerState != .poweredOn
            }
        }
    }

    public struct Selection: Hashable, Sendable {
        public var host: String
        public var vm: String
        public init(host: String, vm: String) {
            self.host = host
            self.vm = vm
        }
    }

    let store: HostStore
    /// The next `refreshDetail` to run once the current fetch finishes (selection moved).
    private var detailPending = false
    private var terminationObserver: NSObjectProtocol?

    public init(store: HostStore = HostStore()) {
        self.store = store
        var infos: [StoredHost] = []
        do {
            infos = try store.load()
        } catch {
            storeError = (error as? PaddockError)?.errorDescription ?? error.localizedDescription
        }
        for info in infos {
            hosts.append(makeHost(info))
        }
        for host in hosts { host.start() }
        // Log out of every host at quit so ESXi doesn't keep the sessions until they time out.
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                                                     queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hosts.forEach { $0.stop() } }
        }
    }

    private func makeHost(_ info: StoredHost) -> HostModel {
        let host = HostModel(info: info)
        host.onPoll = { [weak self] in self?.refreshDetail() }
        host.onPersist = { [weak self] _ in self?.persistHosts() }
        return host
    }

    /// Writes the live list (never a re-read of the file, so a removed host can't come back).
    private func persistHosts() {
        guard storeError == nil else { return }
        do {
            try store.save(hosts.map(\.info))
        } catch {
            storeError = "Couldn't save hosts.json: \(error.localizedDescription)"
        }
    }

    // MARK: Selection

    public var selectedHost: HostModel? {
        guard let selection else { return nil }
        return hosts.first { $0.address == selection.host }
    }

    public var selectedVM: VMSummary? {
        guard let selection, let host = selectedHost else { return nil }
        return host.vm(id: selection.vm)
    }

    public func select(host: HostModel, vm: VMSummary) {
        selection = Selection(host: host.address, vm: vm.ref.value)
        detail = nil
        detailError = nil
        refreshDetail()
    }

    public func selectNothing() {
        selection = nil
        detail = nil
        detailError = nil
    }

    /// The heavy device list for the selected VM — on selection and after each poll. One fetch
    /// at a time; a selection change during a fetch queues another, and a result for a VM that
    /// is no longer selected is dropped.
    public func refreshDetail() {
        guard let selection, let host = selectedHost, let vm = host.vm(id: selection.vm) else {
            detail = nil
            return
        }
        guard !detailRunning else { detailPending = true; return }
        detailRunning = true
        Task { [weak self] in
            guard let self else { return }
            var fetched: VMDetail?
            var failure: String?
            do {
                fetched = try await host.detail(of: vm)
            } catch {
                failure = (error as? VimError)?.errorDescription ?? (error as? PaddockError)?.errorDescription ?? error.localizedDescription
            }
            self.detailRunning = false
            if self.selection == selection {
                if let fetched { self.detail = fetched; self.detailError = nil } else { self.detailError = failure }
            }
            if self.detailPending {
                self.detailPending = false
                self.refreshDetail()
            }
        }
    }

    // MARK: Adding and removing hosts

    /// Logs in with no pinned certificate to learn what the host is and what it presents.
    public func probe(address: String, user: String, password: String) async throws -> HostProbe {
        let session = VimSession(host: address, username: user, password: password, expectedThumbprint: nil)
        let content = try await session.login()
        let thumbprint = session.transport.observedThumbprint
        let subject = session.transport.observedSubject
        await session.logout()
        guard let thumbprint else { throw PaddockError.noCertificate }
        let raw = content.apiVersion.isEmpty ? session.transport.apiVersion : content.apiVersion
        let version = raw.hasSuffix(".0") && raw.count > 4 ? String(raw.dropLast(2)) : raw
        return HostProbe(product: content.fullName, version: version,
                         thumbprintSHA1: thumbprint.sha1, thumbprintSHA256: thumbprint.sha256,
                         certificateSubject: subject)
    }

    /// Saves the host (JSON + Keychain) and starts polling it. `pin` false leaves the thumbprint
    /// unpinned (the user unticked "Trust this certificate"): the first poll then records what
    /// it sees, and a later change is still reported.
    public func addHost(address: String, user: String, password: String, probe: HostProbe, pin: Bool = true) throws {
        let address = address.trimmingCharacters(in: .whitespaces)
        guard !hosts.contains(where: { $0.address == address }) else { throw PaddockError.duplicateHost(address) }
        if let storeError { throw PaddockError.hostsFileUnreadable(store.url.path, storeError) }
        try Keychain.setPassword(password, for: Keychain.hostAccount(address: address))
        let info = StoredHost(address: address, user: user,
                              thumbprint: pin ? probe.thumbprintSHA1 : nil,
                              thumbprintSHA256: pin ? probe.thumbprintSHA256 : nil)
        let model = makeHost(info)
        hosts.append(model)
        hosts.sort { $0.address.localizedStandardCompare($1.address) == .orderedAscending }
        try store.save(hosts.map(\.info))
        model.start()
    }

    /// Removes the host from the JSON, drops its host and guest secrets, stops its polling.
    public func removeHost(_ host: HostModel) {
        host.stop()
        hosts.removeAll { $0.address == host.address }
        persistHosts()
        Keychain.removePassword(for: Keychain.hostAccount(address: host.address))
        for account in Keychain.accounts(prefix: "guest:\(host.address)/") {
            Keychain.removePassword(for: account)
        }
        if selection?.host == host.address { selectNothing() }
    }

    // MARK: Guest logins

    public func saveGuestLogin(user: String, password: String, vm: VMSummary, host: HostModel) throws {
        try host.saveGuestLogin(user: user, password: password, vm: vm)
    }

    // MARK: Counts for the welcome page

    public var totalVMs: Int { hosts.reduce(0) { $0 + $1.vms.count } }
    public var runningVMs: Int { hosts.reduce(0) { $0 + $1.vms.filter { $0.powerState == .poweredOn }.count } }
}
