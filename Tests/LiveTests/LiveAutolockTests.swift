import Foundation
import Testing
import VimClient

/// Reads tools.guest.desktop.autolock (and the related STIG keys) from every running VM.
@Test func liveAutolockSetting() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let host = env["LABDOCK_HOST"], let user = env["LABDOCK_USER"], let pass = env["LABDOCK_PASS"] else { return }
    let s = VimSession(host: host, username: user, password: pass, expectedThumbprint: nil)
    try await s.login()
    let vms = try await s.listVMs().filter { $0.powerState == .poweredOn && !$0.inaccessible }
    let objs = try await s.retrieveProperties(of: vms.map(\.ref), paths: ["config.extraConfig", "name"])
    for o in objs {
        let extra = o.props["config.extraConfig"]?.children ?? []
        let keys = ["tools.guest.desktop.autolock", "tools.setInfo.sizeLimit", "RemoteDisplay.maxConnections", "isolation.tools.copy.disable", "isolation.tools.paste.disable"]
        var found: [String] = []
        for e in extra {
            if let k = e.string("key"), keys.contains(k) { found.append("\(k)=\(e.string("value") ?? "")") }
        }
        print(o.string("name") ?? o.obj.value, "→", found.isEmpty ? "(none set)" : found.joined(separator: ", "))
    }
    await s.logout()
}

/// Reads the flag through the typed API; with LABDOCK_AUTOLOCK=on|off also sets it on LABDOCK_VM.
@Test func liveAutolockToggle() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let host = env["LABDOCK_HOST"], let user = env["LABDOCK_USER"], let pass = env["LABDOCK_PASS"], let name = env["LABDOCK_VM"] else { return }
    let s = VimSession(host: host, username: user, password: pass, expectedThumbprint: nil)
    try await s.login()
    guard let vm = try await s.listVMs().first(where: { $0.name == name }) else { return }
    print("autolock before:", try await s.autolock(vm: vm.ref).map { $0 ? "on" : "off" } ?? "unset")
    if let want = env["LABDOCK_AUTOLOCK"] {
        try await s.setAutolock(vm: vm.ref, want == "on")
        print("autolock after:", try await s.autolock(vm: vm.ref).map { $0 ? "on" : "off" } ?? "unset")
    }
    await s.logout()
}
