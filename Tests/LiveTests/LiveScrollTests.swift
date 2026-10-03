import CoreGraphics
import Foundation
import ImageIO
import MKSClient
import Testing
import UniformTypeIdentifiers
import VimClient

/// Reproduces "the top lines never move": presses Enter on a text console and saves frames.
@Test func liveConsoleScroll() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let host = env["PADDOCK_HOST"], let user = env["PADDOCK_USER"], let pass = env["PADDOCK_PASS"],
          let name = env["PADDOCK_VM"] else { return }
    let s = VimSession(host: host, username: user, password: pass, expectedThumbprint: nil)
    try await s.login()
    guard let vm = try await s.listVMs().first(where: { $0.name == name }) else { Issue.record("no VM \(name)"); return }
    let ticket = try await s.consoleTicket(vm: vm.ref)
    let mks = MKSSession(url: ticket.url, expectedThumbprint: s.transport.observedThumbprint?.sha1)
    mks.connect()
    var frames = 0
    var last: MKSFramebuffer?
    var pressed = 0
    let deadline = ContinuousClock.now + .seconds(20)
    func save(_ fb: MKSFramebuffer, _ tag: String) {
        guard let img = fb.image else { return }
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("paddock-scroll-\(tag).png")
        if let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest); print("saved", out.path)
        }
    }
    for await event in mks.events {
        if case .frame(let fb, let dirty) = event {
            frames += 1
            last = fb
            if frames == 1 { save(fb, "before") }
            if frames >= 1, pressed < 12 {
                pressed += 1
                mks.sendKey(keysym: 0xFF0D, down: true); mks.sendKey(keysym: 0xFF0D, down: false)
                try? await Task.sleep(for: .milliseconds(250))
            }
            print("frame", frames, "dirty", Int(dirty.minX), Int(dirty.minY), Int(dirty.width), Int(dirty.height))
        }
        if ContinuousClock.now > deadline || (pressed >= 12 && frames > 14) { break }
    }
    if let last { save(last, "after") }
    print("frames", frames, "presses", pressed)
    mks.disconnect()
    await s.logout()
}
