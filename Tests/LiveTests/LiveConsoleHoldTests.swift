import Foundation
import MKSClient
import Testing
import VimClient

/// Holds a console open on a static screen for PADDOCK_HOLD seconds (default 60) and fails if it
/// drops: the idle-timeout regression the owner hit ("Socket is not connected" after a pause).
@Test func liveConsoleHold() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let host = env["PADDOCK_HOST"], let user = env["PADDOCK_USER"], let pass = env["PADDOCK_PASS"] else { return }
    let hold = Double(env["PADDOCK_HOLD"] ?? "60") ?? 60
    let s = VimSession(host: host, username: user, password: pass, expectedThumbprint: nil)
    try await s.login()
    let vms = try await s.listVMs()
    guard let vm = vms.first(where: { $0.powerState == .poweredOn && !$0.inaccessible }) else { return }
    let ticket = try await s.consoleTicket(vm: vm.ref)
    let mks = MKSSession(url: ticket.url, expectedThumbprint: s.transport.observedThumbprint?.sha1)
    mks.connect()
    let start = ContinuousClock.now
    var frames = 0
    var dropped: String?
    let deadline = start + .seconds(hold)
    // Consume on this task; a timer task finishes the wait when the hold is over.
    let stopper = Task { try? await Task.sleep(for: .seconds(hold)); mks.disconnect() }
    for await event in mks.events {
        switch event {
        case .frame: frames += 1
        case .state(.disconnected(let why)):
            if ContinuousClock.now < deadline { dropped = why ?? "no reason" }
        default: break
        }
        if dropped != nil { break }
    }
    stopper.cancel()
    print("held", vm.name, "for", Int((ContinuousClock.now - start).components.seconds), "s; frames", frames, "state", mks.state)
    #expect(dropped == nil, "console dropped: \(dropped ?? "")")
    mks.disconnect()
    await s.logout()
}
