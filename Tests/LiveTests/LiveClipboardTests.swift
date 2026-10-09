import Foundation
import Testing
import VimClient

/// Reads the guest's clipboard through Tools the way ⌘C does (LABDOCK_VM + LABDOCK_GUEST_USER /
/// LABDOCK_GUEST_PASS), printing each step's timing and the text that came back.
@Test func liveGuestClipboardRead() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let host = env["LABDOCK_HOST"], let user = env["LABDOCK_USER"], let pass = env["LABDOCK_PASS"],
          let name = env["LABDOCK_VM"], let guser = env["LABDOCK_GUEST_USER"], let gpass = env["LABDOCK_GUEST_PASS"] else { return }
    let s = VimSession(host: host, username: user, password: pass, expectedThumbprint: nil)
    try await s.login()
    guard let vm = try await s.listVMs().first(where: { $0.name == name }) else { Issue.record("no VM \(name)"); return }
    print("vm", vm.name, vm.guestFamily, vm.tools.word)
    let login = GuestLogin(username: guser, password: gpass, interactive: true)
    let start = Date()
    let script = vm.guestFamily == .windows
        ? "$t = Get-Clipboard -Raw -ErrorAction SilentlyContinue; if (-not $t) { Add-Type -AssemblyName System.Windows.Forms; $t = [System.Windows.Forms.Clipboard]::GetText() }; [Console]::Out.Write($t)"
        : "if command -v wl-paste >/dev/null 2>&1; then wl-paste -n; elif command -v xclip >/dev/null 2>&1; then DISPLAY=:0 xclip -o -selection clipboard; else xsel -ob; fi"
    do {
        let r = try await s.run(script, shell: vm.guestFamily == .windows ? .powershell : .sh, vm: vm.ref, login: login, family: vm.guestFamily, timeout: 60)
        print("exit", r.exitCode ?? -1, "in", String(format: "%.1f s", Date().timeIntervalSince(start)))
        print("clipboard text (\(r.output.count) chars):", r.output.prefix(300))
    } catch {
        print("failed after", String(format: "%.1f s", Date().timeIntervalSince(start)), ":", (error as? LocalizedError)?.errorDescription ?? "\(error)")
        Issue.record("read failed: \(error)")
    }
    await s.logout()
}

/// The two-way watcher: push text to the guest, wait for the ack, read it back through the
/// guest → Mac path. Same env vars as above.
@Test func liveGuestClipboardSync() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let host = env["LABDOCK_HOST"], let user = env["LABDOCK_USER"], let pass = env["LABDOCK_PASS"],
          let name = env["LABDOCK_VM"], let guser = env["LABDOCK_GUEST_USER"], let gpass = env["LABDOCK_GUEST_PASS"] else { return }
    let s = VimSession(host: host, username: user, password: pass, expectedThumbprint: nil)
    try await s.login()
    guard let vm = try await s.listVMs().first(where: { $0.name == name }) else { Issue.record("no VM \(name)"); return }
    let sync = GuestClipboardSync(session: s, vm: vm.ref, login: GuestLogin(username: guser, password: gpass), family: vm.guestFamily)
    var t = Date()
    try await sync.start()
    print("started in", String(format: "%.1f s", Date().timeIntervalSince(t)))
    t = Date()
    let ready = await sync.waitUntilReady(timeout: 30)
    print("watcher ready:", ready, "after", String(format: "%.1f s", Date().timeIntervalSince(t)))
    let login = GuestLogin(username: guser, password: gpass, interactive: true)
    let dir = await sync.directory
    let files = (try? await s.listFiles(vm: vm.ref, login: login, path: dir)) ?? []
    print("dir", dir, "files:", files.map { "\($0.name)(\($0.size))" })
    if let pid = await sync.processID {
        let ps = (try? await s.listProcesses(vm: vm.ref, login: login, pids: [pid])) ?? []
        print("watcher pid", pid, ps.map { "ended=\($0.ended != nil) exit=\($0.exitCode ?? -1) cmd=\($0.commandLine.prefix(80))" })
    }
    if files.contains(where: { $0.name == "watch.log" }), let log = try? await s.download(dir + "\\watch.log", vm: vm.ref, login: login) {
        print("watch.log:", String(decoding: log.prefix(800), as: UTF8.self))
    }
    let first = try await sync.pollGuest()
    print("guest clipboard at start:", first.map { "\($0.count) chars: \($0.prefix(60))" } ?? "nil")
    t = Date()
    let probe = "labdock sync test \(Int(Date().timeIntervalSince1970))"
    let acked = try await sync.push(probe, timeout: 5)
    print("push acked:", acked, "in", String(format: "%.1f s", Date().timeIntervalSince(t)))
    let after = (try? await s.listFiles(vm: vm.ref, login: login, path: dir)) ?? []
    print("files after push:", after.map { "\($0.name)(\($0.size))" })
    try await Task.sleep(for: .seconds(1))
    let back = try await sync.pollGuest()
    print("read back:", back ?? "nil")
    #expect(acked)
    await sync.stop()
    await s.logout()
}
