import Foundation
import MKSClient
import Testing
import VimClient

/// Asks a Tools-equipped guest (PADDOCK_VM) to change its screen size and waits for `.resized`.
@Test func liveDesktopResize() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let host = env["PADDOCK_HOST"], let user = env["PADDOCK_USER"], let pass = env["PADDOCK_PASS"],
          let name = env["PADDOCK_VM"] else { return }
    let s = VimSession(host: host, username: user, password: pass, expectedThumbprint: nil)
    try await s.login()
    guard let vm = try await s.listVMs().first(where: { $0.name == name }) else { Issue.record("no VM \(name)"); return }
    print("vm", vm.name, vm.tools.word)
    let ticket = try await s.consoleTicket(vm: vm.ref)
    let mks = MKSSession(url: ticket.url, expectedThumbprint: s.transport.observedThumbprint?.sha1)
    mks.connect()
    var frames = 0
    var sizes: [(Int, Int)] = []
    var refused: Int?
    let deadline = ContinuousClock.now + .seconds(25)
    var asked = false
    for await event in mks.events {
        switch event {
        case .frame(let f, _):
            frames += 1
            if frames == 1, !asked {
                asked = true
                try? await Task.sleep(for: .seconds(1))   // let ServerCaps arrive
                let (w, h) = f.width == 1600 ? (1280, 800) : (1600, 900)
                let caps = await mks.capabilities()
                print("caps", String(caps.vmwCaps, radix: 16), "extendedDesktopSize", caps.extendedDesktopSize)
                print("current", f.width, "x", f.height, "→ asking", w, "x", h)
                mks.requestDesktopSize(width: w, height: h)
            }
        case .resized(let w, let h):
            print("resized to", w, "x", h); sizes.append((w, h))
        case .resizeRefused(let status): print("refused", status); refused = status
        case .state(.disconnected(let why)): print("disconnected", why ?? "-")
        default: break
        }
        if !sizes.isEmpty || refused != nil || ContinuousClock.now > deadline { break }
    }
    print("frames", frames, "sizes", sizes, "refused", refused ?? -1)
    #expect(!sizes.isEmpty || refused != nil, "no answer to SetDesktopSize")
    mks.disconnect()
    await s.logout()
}
