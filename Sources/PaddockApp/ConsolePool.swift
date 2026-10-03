import Foundation
import MKSClient

/// Keeps console streams alive while the user is on another VM or tab (owner, 3 Oct 2026:
/// Windows locked itself every time the last console client went away; the ESXi web console
/// avoids that only because its tab stays open). A `ConsoleBackend` owns one `MKSSession` and
/// its single event consumer; the console view attaches a sink when it shows the VM and
/// detaches when it leaves, and the stream keeps running in the background. Backends go away
/// when the stream drops, when the VM stops running, or when more than `limit` are kept.
@MainActor
final class ConsoleBackend {
    let key: String
    let session: MKSSession
    private(set) var state: MKSState = .idle
    private(set) var frame: MKSFramebuffer?
    private(set) var cursor: MKSCursor?
    /// Set by the view while it shows this console; every event is forwarded to it.
    var sink: ((MKSEvent) -> Void)?
    var lastDetached = Date()
    private var consumer: Task<Void, Never>?

    init(key: String, session: MKSSession) {
        self.key = key
        self.session = session
        consumer = Task { [weak self] in
            for await event in session.events {
                guard let self else { return }
                switch event {
                case .state(let s): self.state = s
                case .frame(let fb, _): self.frame = fb
                case .cursor(let c): self.cursor = c
                default: break
                }
                self.sink?(event)
                if case .state(.disconnected) = event { ConsolePool.shared.drop(key) }
            }
        }
    }

    var isLive: Bool {
        switch state {
        case .connecting, .connected: true
        default: false
        }
    }

    func disconnect() {
        sink = nil
        session.disconnect()
        consumer?.cancel()
        consumer = nil
    }
}

@MainActor
final class ConsolePool {
    static let shared = ConsolePool()
    private var backends: [String: ConsoleBackend] = [:]
    /// How many background consoles to keep; the least recently shown goes first.
    let limit = 6

    func backend(for key: String) -> ConsoleBackend? { backends[key] }

    func put(_ backend: ConsoleBackend) {
        backends[backend.key]?.disconnect()
        backends[backend.key] = backend
        trim()
    }

    func drop(_ key: String) {
        backends.removeValue(forKey: key)?.disconnect()
    }

    /// A VM that stopped running has no console to keep.
    func dropIfNotRunning(key: String, running: Bool) {
        if !running { drop(key) }
    }

    private func trim() {
        let detached = backends.values.filter { $0.sink == nil }.sorted { $0.lastDetached < $1.lastDetached }
        var excess = backends.count - limit
        for b in detached where excess > 0 {
            drop(b.key)
            excess -= 1
        }
    }

    func disconnectAll() {
        for b in backends.values { b.disconnect() }
        backends.removeAll()
    }
}
