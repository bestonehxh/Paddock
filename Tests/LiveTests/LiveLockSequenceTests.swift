import CoreGraphics
import Foundation
import ImageIO
import MKSClient
import Testing
import UniformTypeIdentifiers
import VimClient

/// Replays the app's switch-away sequence (console + clipboard watcher, optional keys, then
/// stop + disconnect), reconnects and snapshots. PADDOCK_SEQ = "sync,keys" picks the pieces.
@Test func liveLockSequence() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let host = env["PADDOCK_HOST"], let user = env["PADDOCK_USER"], let pass = env["PADDOCK_PASS"], let name = env["PADDOCK_VM"],
          let guser = env["PADDOCK_GUEST_USER"], let gpass = env["PADDOCK_GUEST_PASS"] else { return }
    let pieces = Set((env["PADDOCK_SEQ"] ?? "").split(separator: ",").map(String.init))
    let s = VimSession(host: host, username: user, password: pass, expectedThumbprint: nil)
    try await s.login()
    guard let vm = try await s.listVMs().first(where: { $0.name == name }) else { return }

    func snapshot(_ tag: String) async throws {
        let ticket = try await s.consoleTicket(vm: vm.ref)
        guard let ticketURL = ticket.url else { Issue.record("unusable ticket URL"); return }
        let mks = MKSSession(url: ticketURL, expectedThumbprint: s.transport.observedThumbprint?.sha1)
        mks.connect()
        var last: MKSFramebuffer?
        var nudged = false
        let guardTask = Task { try? await Task.sleep(for: .seconds(12)); mks.disconnect() }
        for await event in mks.events {
            if case .frame(let fb, _) = event {
                last = fb
                if !nudged { nudged = true; mks.sendPointer(x: 300, y: 300, buttons: []); mks.sendPointer(x: 320, y: 310, buttons: [])
                    Task { try? await Task.sleep(for: .milliseconds(2000)); mks.disconnect() } }
            }
            if case .state(.disconnected) = event { break }
        }
        guardTask.cancel()
        if let img = last?.image, let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "/tmp/paddock-seq-\(tag).png") as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest); print("snapshot", tag, "saved")
        }
    }

    try await snapshot("before-\(pieces.sorted().joined(separator: "-"))")
    try await Task.sleep(for: .seconds(2))
    // 1. The console as the app opens it.
    let ticket = try await s.consoleTicket(vm: vm.ref)
    guard let ticketURL = ticket.url else { Issue.record("unusable ticket URL"); return }
    let mks = MKSSession(url: ticketURL, expectedThumbprint: s.transport.observedThumbprint?.sha1)
    mks.connect()
    let consumer = Task { for await e in mks.events { if case .state(let st) = e { print("state", st) } } }
    try await Task.sleep(for: .seconds(2))
    var sync: GuestClipboardSync?
    if pieces.contains("sync") {
        let sy = GuestClipboardSync(session: s, vm: vm.ref, login: GuestLogin(username: guser, password: gpass), family: .windows)
        try await sy.start(); print("sync ready:", await sy.waitUntilReady(timeout: 20)); sync = sy
    }
    if pieces.contains("sendtext") {
        // The ⌘V typing path on a console without a clipboard: sendText through the stream.
        let skipped = mks.sendText("paddock")
        print("sendText skipped:", skipped)
        try await Task.sleep(for: .seconds(2))
        if let fb = await withCheckedContinuation({ (c: CheckedContinuation<MKSFramebuffer?, Never>) in c.resume(returning: mks.framebuffer) }),
           let img = fb.image, let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "/tmp/paddock-seq-typed.png") as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest); print("snapshot typed saved")
        }
        for _ in 0..<7 { mks.sendKey(keysym: 0xFF08, down: true); mks.sendKey(keysym: 0xFF08, down: false) }   // backspace it away
    }
    if pieces.contains("type") {
        // Plain letters, as the app sends them when the user types (focus on the desktop: harmless).
        for k: UInt32 in [0x61, 0x62, 0x63] { mks.sendKey(keysym: k, down: true); mks.sendKey(keysym: k, down: false) }
        print("typed abc")
    }
    if pieces.contains("keys") {
        // Shift tap, then the pointer, like a user touching the console.
        mks.sendKey(keysym: MKSKeyMap.shift, down: true); mks.sendKey(keysym: MKSKeyMap.shift, down: false)
        mks.sendPointer(x: 400, y: 400, buttons: [])
        print("keys sent")
    }
    try await Task.sleep(for: .seconds(3))
    // 2. Switch away: the app stops sharing first, then disconnects.
    if let sync { await sync.stop(); print("sync stopped") }
    mks.disconnect(); print("disconnected")
    consumer.cancel()
    try await Task.sleep(for: .seconds(3))
    // 3. Back: what does the screen show?
    try await snapshot("after-\(pieces.sorted().joined(separator: "-"))")
    await s.logout()
}
