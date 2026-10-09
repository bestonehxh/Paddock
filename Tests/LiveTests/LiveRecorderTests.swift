import CoreGraphics
import Foundation
import ImageIO
import MKSClient
import Testing
import UniformTypeIdentifiers
import VimClient

/// Records the console for PADDOCK_RECORD_SECONDS: a timestamped PNG whenever a frame arrives
/// (at most 2/s) into /tmp/paddock-rec/, plus a log line per frame. Used to catch the moment
/// Windows locks while the owner reproduces the switch in the app.
@Test func liveConsoleRecorder() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let host = env["PADDOCK_HOST"], let user = env["PADDOCK_USER"], let pass = env["PADDOCK_PASS"], let name = env["PADDOCK_VM"] else { return }
    let seconds = Double(env["PADDOCK_RECORD_SECONDS"] ?? "60") ?? 60
    let dir = URL(fileURLWithPath: "/tmp/paddock-rec")
    try? FileManager.default.removeItem(at: dir)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let s = VimSession(host: host, username: user, password: pass, expectedThumbprint: nil)
    try await s.login()
    guard let vm = try await s.listVMs().first(where: { $0.name == name }) else { return }
    let ticket = try await s.consoleTicket(vm: vm.ref)
    guard let ticketURL = ticket.url else { Issue.record("unusable ticket URL"); return }
    let mks = MKSSession(url: ticketURL, expectedThumbprint: s.transport.observedThumbprint?.sha1)
    mks.connect()
    let stopper = Task { try? await Task.sleep(for: .seconds(seconds)); mks.disconnect() }
    var lastSave = Date.distantPast
    var n = 0
    let fmt = DateFormatter(); fmt.dateFormat = "HH:mm:ss.SSS"
    for await event in mks.events {
        switch event {
        case .frame(let fb, let dirty):
            let now = Date()
            guard now.timeIntervalSince(lastSave) >= 0.5, dirty.width * dirty.height > 2000 else { continue }
            lastSave = now; n += 1
            if let img = fb.image, let dest = CGImageDestinationCreateWithURL(dir.appendingPathComponent("\(fmt.string(from: now)).png") as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
            }
            print("frame", fmt.string(from: now), "dirty", Int(dirty.width), "x", Int(dirty.height))
        case .state(let st): print("state", fmt.string(from: Date()), st)
        case .resized(let w, let h): print("resized", fmt.string(from: Date()), w, "x", h)
        case .resizeRefused(let st): print("resizeRefused", fmt.string(from: Date()), st)
        default: break
        }
        if case .state(.disconnected) = event { break }
    }
    stopper.cancel()
    print("recorded", n, "frames")
    await s.logout()
}
