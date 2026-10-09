import CoreGraphics
import Foundation
import ImageIO
import MKSClient
import Testing
import UniformTypeIdentifiers
import VimClient

/// Connects, nudges the mouse, waits 2.5 s, saves the latest frame (LABDOCK_SNAP), disconnects.
@Test func liveLockProbe() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let host = env["LABDOCK_HOST"], let user = env["LABDOCK_USER"], let pass = env["LABDOCK_PASS"], let name = env["LABDOCK_VM"] else { return }
    let s = VimSession(host: host, username: user, password: pass, expectedThumbprint: nil)
    try await s.login()
    guard let vm = try await s.listVMs().first(where: { $0.name == name }) else { return }
    let ticket = try await s.consoleTicket(vm: vm.ref)
    guard let ticketURL = ticket.url else { Issue.record("unusable ticket URL"); return }
    let mks = MKSSession(url: ticketURL, expectedThumbprint: s.transport.observedThumbprint?.sha1)
    mks.connect()
    let stopper = Task { try? await Task.sleep(for: .seconds(12)); mks.disconnect() }
    var last: MKSFramebuffer?
    var nudged = false
    var frames = 0
    let settle = Task<Void, Never> { }
    _ = settle
    for await event in mks.events {
        switch event {
        case .frame(let fb, _):
            frames += 1
            last = fb
            if !nudged {
                nudged = true
                mks.sendPointer(x: 300, y: 300, buttons: [])
                mks.sendPointer(x: 320, y: 310, buttons: [])
                Task { try? await Task.sleep(for: .milliseconds(2500)); mks.disconnect() }
            }
        case .state(.disconnected): break
        default: break
        }
        if case .state(.disconnected) = event { break }
    }
    stopper.cancel()
    if let img = last?.image {
        let out = URL(fileURLWithPath: "/tmp/\(env["LABDOCK_SNAP"] ?? "probe").png")
        if let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
        }
        print("saved", out.path, last!.width, last!.height, "frames", frames)
    } else { print("no frame") }
    await s.logout()
}
