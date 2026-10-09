import CoreGraphics
import Foundation
import ImageIO
import MKSClient
import Testing
import UniformTypeIdentifiers
import VimClient

/// Connects, saves the first frame (or gives up after 15 s), disconnects. LABDOCK_SNAP names the file.
@Test func liveConsoleSnapshot() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let host = env["LABDOCK_HOST"], let user = env["LABDOCK_USER"], let pass = env["LABDOCK_PASS"], let name = env["LABDOCK_VM"] else { return }
    let s = VimSession(host: host, username: user, password: pass, expectedThumbprint: nil)
    try await s.login()
    guard let vm = try await s.listVMs().first(where: { $0.name == name }) else { return }
    let ticket = try await s.consoleTicket(vm: vm.ref)
    guard let ticketURL = ticket.url else { Issue.record("unusable ticket URL"); return }
    let mks = MKSSession(url: ticketURL, expectedThumbprint: s.transport.observedThumbprint?.sha1)
    mks.connect()
    let stopper = Task { try? await Task.sleep(for: .seconds(15)); mks.disconnect() }
    var saved = false
    for await event in mks.events {
        if case .frame(let fb, _) = event, let img = fb.image, !saved {
            let out = URL(fileURLWithPath: "/tmp/\(env["LABDOCK_SNAP"] ?? "labdock-snap").png")
            if let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest); print("saved", out.path, fb.width, fb.height)
            }
            saved = true
            break
        }
        if case .state(.disconnected) = event { break }
    }
    stopper.cancel()
    mks.disconnect()
    await s.logout()
}
