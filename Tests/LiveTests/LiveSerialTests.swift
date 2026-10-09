import Foundation
import Testing
import VimClient

/// Read-only: the test VMs' power state and serial ports, and the ESXi firewall rule for
/// serial-over-network. LABDOCK_VMS = comma-separated names.
@Test func liveSerialProbe() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let host = env["LABDOCK_HOST"], let user = env["LABDOCK_USER"], let pass = env["LABDOCK_PASS"],
          let names = env["LABDOCK_VMS"]?.split(separator: ",").map(String.init) else { return }
    let s = VimSession(host: host, username: user, password: pass, expectedThumbprint: nil)
    try await s.login()
    let vms = try await s.listVMs()
    for name in names {
        guard let vm = vms.first(where: { $0.name == name }) else { print("missing", name); continue }
        let objs = try await s.retrieveProperties(of: [vm.ref], paths: ["config.hardware.device"])
        let serials = objs.first?.props["config.hardware.device"]?.children.filter { $0.xsiType == "VirtualSerialPort" } ?? []
        print(vm.name, "|", vm.powerState.word, "|", vm.guestFamily, "|", vm.tools.word, "| serial ports:", serials.count,
              serials.map { "\($0["backing"]?.xsiType ?? "?") \($0["backing"]?.string("serviceURI") ?? $0["backing"]?.string("fileName") ?? "")" })
    }
    // Firewall: HostSystem.configManager.firewallSystem → firewallInfo.ruleset[]
    let hosts = try await s.retrieveAll(type: "HostSystem", paths: ["configManager.firewallSystem", "name"])
    guard let h = hosts.first, let fw = h.ref("configManager.firewallSystem") else { print("no firewall system"); return }
    let info = try await s.retrieveProperties(of: [fw], paths: ["firewallInfo"])
    let rulesets = info.first?.props["firewallInfo"]?.all("ruleset") ?? []
    for r in rulesets where (r.string("key") ?? "").lowercased().contains("serial") {
        print("ruleset", r.string("key") ?? "", "enabled:", r.string("enabled") ?? "", "label:", r.string("label") ?? "",
              r.all("rule").map { "\($0.string("direction") ?? "") \($0.string("protocol") ?? "") \($0.string("port") ?? "")-\($0.string("endPort") ?? "")" })
    }
    await s.logout()
}

/// Opt-in and run by the owner (LABDOCK_SERIAL_VM): enables the ESXi serial-over-network
/// firewall rule, powers the VM off, adds a serial port served at telnet://:LABDOCK_SERIAL_PORT
/// on the host, powers it on. Not run by Claude: it opens a port on the host.
@Test func liveSerialSetup() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let host = env["LABDOCK_HOST"], let user = env["LABDOCK_USER"], let pass = env["LABDOCK_PASS"],
          let name = env["LABDOCK_SERIAL_VM"] else { return }
    let port = env["LABDOCK_SERIAL_PORT"] ?? "2001"
    let s = VimSession(host: host, username: user, password: pass, expectedThumbprint: nil)
    try await s.login()
    guard let vm = try await s.listVMs().first(where: { $0.name == name }) else { Issue.record("no VM \(name)"); return }

    // 1. Firewall rule.
    let hosts = try await s.retrieveAll(type: "HostSystem", paths: ["configManager.firewallSystem"])
    if let fw = hosts.first?.ref("configManager.firewallSystem") {
        try await s.call("EnableRuleset", this: fw, [.text("id", "remoteSerialPort")])
        print("firewall: remoteSerialPort enabled")
    }

    // 2. Power off (guest shutdown first, hard off after 150 s).
    if vm.powerState != .poweredOff {
        if vm.tools.isRunning {
            try await s.power(.shutdownGuest, vm: vm.ref)
            print("shutdown requested")
        } else {
            try await s.power(.powerOff, vm: vm.ref)
        }
        var waited = 0
        while waited < 150, try await s.summary(of: vm.ref)?.powerState != .poweredOff {
            try await Task.sleep(for: .seconds(5)); waited += 5
        }
        if try await s.summary(of: vm.ref)?.powerState != .poweredOff {
            print("still on after \(waited) s: powering off")
            try await s.power(.powerOff, vm: vm.ref)
        }
        print("powered off after ~\(waited) s")
    }

    // 3. Add the serial port.
    let device = XMLOut.Element.typed("device", "VirtualSerialPort", [
        .int("key", -1),
        .typed("backing", "VirtualSerialPortURIBackingInfo", [.text("serviceURI", "telnet://:\(port)"), .text("direction", "server")]),
        XMLOut.Element("connectable", children: [.bool("startConnected", true), .bool("allowGuestControl", true), .bool("connected", true)]),
        .bool("yieldOnPoll", true),
    ])
    let change = XMLOut.Element("deviceChange", children: [.text("operation", "add"), device])
    try await s.runTask("ReconfigVM_Task", this: vm.ref, [XMLOut.Element("spec", children: [change])])
    print("serial port added: telnet://\(host):\(port)")

    // 4. Power on.
    try await s.power(.powerOn, vm: vm.ref)
    print("powered on")
    await s.logout()
}

/// Cleanup after the serial experiment (LABDOCK_SERIAL_CLEANUP_VM): powers the VM off, removes
/// its network serial port(s), powers it back on, and disables the host firewall rule.
@Test func liveSerialCleanup() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let host = env["LABDOCK_HOST"], let user = env["LABDOCK_USER"], let pass = env["LABDOCK_PASS"],
          let name = env["LABDOCK_SERIAL_CLEANUP_VM"] else { return }
    let s = VimSession(host: host, username: user, password: pass, expectedThumbprint: nil)
    try await s.login()
    guard let vm = try await s.listVMs().first(where: { $0.name == name }) else { Issue.record("no VM \(name)"); return }
    let objs = try await s.retrieveProperties(of: [vm.ref], paths: ["config.hardware.device"])
    let serials = objs.first?.props["config.hardware.device"]?.children.filter { $0.xsiType == "VirtualSerialPort" } ?? []
    print("serial ports:", serials.compactMap { $0.int("key") })
    if !serials.isEmpty {
        if vm.powerState != .poweredOff {
            try await s.power(vm.tools.isRunning ? .shutdownGuest : .powerOff, vm: vm.ref)
            var waited = 0
            while waited < 150, try await s.summary(of: vm.ref)?.powerState != .poweredOff { try await Task.sleep(for: .seconds(5)); waited += 5 }
            if try await s.summary(of: vm.ref)?.powerState != .poweredOff { try await s.power(.powerOff, vm: vm.ref) }
            print("powered off after ~\(waited) s")
        }
        let changes = serials.compactMap { d -> XMLOut.Element? in
            guard let key = d.int("key") else { return nil }
            return XMLOut.Element("deviceChange", children: [.text("operation", "remove"), .typed("device", "VirtualSerialPort", [.int("key", key), .bool("yieldOnPoll", true)])])
        }
        try await s.runTask("ReconfigVM_Task", this: vm.ref, [XMLOut.Element("spec", children: changes)])
        print("serial ports removed")
        try await s.power(.powerOn, vm: vm.ref)
        print("powered on")
    }
    let hosts = try await s.retrieveAll(type: "HostSystem", paths: ["configManager.firewallSystem"])
    if let fw = hosts.first?.ref("configManager.firewallSystem") {
        try await s.call("DisableRuleset", this: fw, [.text("id", "remoteSerialPort")])
        print("firewall: remoteSerialPort disabled")
    }
    await s.logout()
}
