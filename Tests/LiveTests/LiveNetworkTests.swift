import Foundation
import Testing
import VimClient

/// Port groups on the host and the adapters of PADDOCK_VM; with PADDOCK_NIC_NOOP=1 re-applies
/// the first adapter's current settings (a no-op edit) to prove the reconfigure payload.
@Test func liveNetworkInventory() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let host = env["PADDOCK_HOST"], let user = env["PADDOCK_USER"], let pass = env["PADDOCK_PASS"], let name = env["PADDOCK_VM"] else { return }
    let s = VimSession(host: host, username: user, password: pass, expectedThumbprint: nil)
    try await s.login()
    let groups = try await s.portGroups()
    print("port groups:", groups.map { "\($0.name) (vlan \($0.vlanID), \($0.vSwitch))" })
    guard let vm = try await s.listVMs().first(where: { $0.name == name }) else { return }
    let nics = try await s.networkAdapters(vm: vm.ref)
    for n in nics { print("nic", n.key, n.typeWord, n.label, n.macAddress, n.addressType, "→", n.network, "connected:", n.connected, "startConnected:", n.startConnected) }
    if env["PADDOCK_NIC_NOOP"] == "1", let first = nics.first {
        let t = Date()
        try await s.setNetworkAdapter(vm: vm.ref, adapter: first, network: first.network, connected: first.connected, startConnected: first.startConnected)
        print("no-op edit ok in", String(format: "%.1f s", Date().timeIntervalSince(t)))
        let after = try await s.networkAdapters(vm: vm.ref)
        print("after:", after.map { "\($0.label) → \($0.network) \($0.connected)" })
    }
    await s.logout()
}

/// Host networking: lists switches/NICs; with PADDOCK_PG_TEST=1 creates, re-VLANs and removes
/// a port group named Paddock-Test on vSwitch0 (nothing is left behind).
@Test func liveHostNetworking() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let host = env["PADDOCK_HOST"], let user = env["PADDOCK_USER"], let pass = env["PADDOCK_PASS"] else { return }
    let s = VimSession(host: host, username: user, password: pass, expectedThumbprint: nil)
    try await s.login()
    var net = try await s.hostNetworking()
    for v in net.switches { print("vswitch", v.name, "ports", v.numPorts, "mtu", v.mtu, "uplinks", v.uplinks, "pgs", v.portGroups.count) }
    for n in net.nics { print("pnic", n.device, n.mac, n.linkMbps.map { "\($0) Mb" } ?? "down") }
    print("free nics:", net.freeNICs.map(\.device))
    if env["PADDOCK_PG_TEST"] == "1" {
        try await s.addPortGroup(name: "Paddock-Test", vlan: 3999, vSwitch: "vSwitch0")
        net = try await s.hostNetworking()
        print("after add:", net.portGroups.filter { $0.name.hasPrefix("Paddock") }.map { "\($0.name) vlan \($0.vlanID)" })
        try await s.updatePortGroup(current: "Paddock-Test", name: "Paddock-Test", vlan: 3998, vSwitch: "vSwitch0")
        net = try await s.hostNetworking()
        print("after update:", net.portGroups.filter { $0.name.hasPrefix("Paddock") }.map { "\($0.name) vlan \($0.vlanID)" })
        try await s.removePortGroup(name: "Paddock-Test")
        net = try await s.hostNetworking()
        print("after remove:", net.portGroups.filter { $0.name.hasPrefix("Paddock") }.count)
    }
    await s.logout()
}
