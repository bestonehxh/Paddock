import Foundation
import Testing
import VimClient

/// Lists a guest folder through Tools (LABDOCK_GUEST_DIR), for diagnosing the clipboard watcher.
@Test func liveGuestDirList() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let host = env["LABDOCK_HOST"], let user = env["LABDOCK_USER"], let pass = env["LABDOCK_PASS"],
          let name = env["LABDOCK_VM"], let guser = env["LABDOCK_GUEST_USER"], let gpass = env["LABDOCK_GUEST_PASS"],
          let dir = env["LABDOCK_GUEST_DIR"] else { return }
    let s = VimSession(host: host, username: user, password: pass, expectedThumbprint: nil)
    try await s.login()
    guard let vm = try await s.listVMs().first(where: { $0.name == name }) else { return }
    print("moref", vm.ref.value, vm.name)
    if let other = env["LABDOCK_FIND_REF"], let o = try await s.listVMs().first(where: { $0.ref.value == other }) { print("ref", other, "is", o.name) }
    let login = GuestLogin(username: guser, password: gpass, interactive: true)
    let files = try await s.listFiles(vm: vm.ref, login: login, path: dir)
    for f in files { print(f.kind.rawValue, f.name, f.size, f.modified.map { $0.formatted(date: .omitted, time: .standard) } ?? "") }
    let ps = try await s.listProcesses(vm: vm.ref, login: login)
    for p in ps where p.commandLine.localizedCaseInsensitiveContains("labdock") { print("process", p.pid, p.commandLine.prefix(160)) }
    await s.logout()
}
