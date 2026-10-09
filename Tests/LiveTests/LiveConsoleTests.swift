import CoreGraphics
import Foundation
import ImageIO
import MKSClient
import Testing
import UniformTypeIdentifiers
import VimClient

/// Connects the console of a powered-on VM and waits for the first frame. Needs the env vars.
@Test func liveConsoleFirstFrame() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let host = env["PADDOCK_HOST"], let user = env["PADDOCK_USER"], let pass = env["PADDOCK_PASS"] else { return }
    let s = VimSession(host: host, username: user, password: pass, expectedThumbprint: nil)
    try await s.login()
    let thumb = await s.transport.observedThumbprint?.sha1
    let vms = try await s.listVMs()
    let wanted = env["PADDOCK_VM"]
    guard let vm = vms.first(where: { wanted == nil ? $0.powerState == .poweredOn : $0.name == wanted }) else {
        Issue.record("no powered-on VM"); return
    }
    print("console of", vm.name, vm.ref)
    let ticket = try await s.consoleTicket(vm: vm.ref)
    guard let ticketURL = ticket.url else { Issue.record("unusable ticket URL"); return }
    print("ticket url", ticketURL)
    let mks = MKSSession(url: ticketURL, expectedThumbprint: thumb)
    mks.connect()
    var frames = 0
    var saved = false
    let deadline = ContinuousClock.now + .seconds(20)
    loop: for await event in mks.events {
        switch event {
        case .state(let st):
            print("state", st)
            if case .disconnected(let why) = st { Issue.record("disconnected: \(why ?? "-")"); break loop }
        case .frame(let fb, let dirty):
            frames += 1
            if frames == 1 || frames % 20 == 0 { print("frame", frames, fb.width, "x", fb.height, "dirty", dirty) }
            if !saved, let img = fb.image, frames >= 3 {
                let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("paddock-console.png")
                if let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil) {
                    CGImageDestinationAddImage(dest, img, nil)
                    CGImageDestinationFinalize(dest)
                    print("saved", out.path)
                    saved = true
                }
            }
            if frames >= 10 { break loop }
        case .resized(let w, let h): print("resized", w, h)
        case .cursor: print("cursor")
        case .cursorPosition: break
        case .clipboard(let t): print("clipboard", t.prefix(40))
        case .resizeRefused(let st): print("resize refused", st)
        }
        if ContinuousClock.now > deadline { break }
    }
    print("frames received:", frames, "state:", mks.state)
    #expect(frames >= 1)
    mks.disconnect()
    await s.logout()
}
