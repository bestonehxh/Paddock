import Foundation

/// A port group on the host's standard vSwitches: what a VM's network adapter can plug into.
public struct PortGroup: Sendable, Hashable, Identifiable {
    public var name: String
    public var vlanID: Int
    public var vSwitch: String
    public var id: String { name }
}

/// One network adapter of a VM, as needed to edit it.
public struct NetworkAdapter: Sendable, Hashable, Identifiable {
    public var key: Int
    public var deviceType: String        // VirtualVmxnet3, VirtualE1000e, VirtualE1000, …
    public var label: String
    public var macAddress: String
    public var addressType: String       // generated / manual / assigned
    public var network: String           // port group name
    public var connected: Bool
    public var startConnected: Bool
    public var id: Int { key }

    public var typeWord: String {
        switch deviceType {
        case "VirtualVmxnet3": "vmxnet3"
        case "VirtualE1000e": "e1000e"
        case "VirtualE1000": "e1000"
        case "VirtualVmxnet2": "vmxnet2"
        case "VirtualPCNet32": "pcnet32"
        case "VirtualSriovEthernetCard": "SR-IOV"
        default: deviceType.replacingOccurrences(of: "Virtual", with: "")
        }
    }
}

public enum AdapterType: String, Sendable, CaseIterable {
    case vmxnet3 = "VirtualVmxnet3"
    case e1000e = "VirtualE1000e"
    case e1000 = "VirtualE1000"
    public var title: String {
        switch self {
        case .vmxnet3: "vmxnet3 (needs Tools or a modern OS)"
        case .e1000e: "e1000e (works everywhere)"
        case .e1000: "e1000 (old guests)"
        }
    }
}

extension VimSession {
    /// The host's standard port groups, with VLAN IDs.
    public func portGroups() async throws -> [PortGroup] {
        let hosts = try await retrieveAll(type: "HostSystem", paths: ["configManager.networkSystem"])
        guard let ns = hosts.first?.ref("configManager.networkSystem") else { return [] }
        let info = try await retrieveProperties(of: [ns], paths: ["networkInfo.portgroup"])
        let groups = info.first?.props["networkInfo.portgroup"]?.children ?? []
        return groups.compactMap { g -> PortGroup? in
            guard let spec = g["spec"], let name = spec.string("name") else { return nil }
            return PortGroup(name: name, vlanID: spec.int("vlanId") ?? 0, vSwitch: spec.string("vswitchName") ?? "")
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The VM's network adapters.
    public func networkAdapters(vm: MoRef) async throws -> [NetworkAdapter] {
        let objs = try await retrieveProperties(of: [vm], paths: ["config.hardware.device"])
        return (objs.first?.props["config.hardware.device"]?.children ?? []).compactMap { d -> NetworkAdapter? in
            let type = d.xsiType ?? ""
            guard type.hasPrefix("VirtualVmxnet") || type.hasPrefix("VirtualE1000") || type == "VirtualPCNet32" || type == "VirtualSriovEthernetCard",
                  let key = d.int("key") else { return nil }
            return NetworkAdapter(
                key: key, deviceType: type, label: d["deviceInfo"]?.string("label") ?? "Network adapter",
                macAddress: d.string("macAddress") ?? "", addressType: d.string("addressType") ?? "generated",
                network: d["backing"]?.string("deviceName") ?? d["backing"]?["network"].map { _ in "" } ?? "",
                connected: d["connectable"]?.bool("connected") ?? false,
                startConnected: d["connectable"]?.bool("startConnected") ?? true)
        }
    }

    private func connectable(connected: Bool, startConnected: Bool) -> XMLOut.Element {
        XMLOut.Element("connectable", children: [
            .bool("startConnected", startConnected), .bool("allowGuestControl", true), .bool("connected", connected),
        ])
    }

    private func backing(network: String) -> XMLOut.Element {
        .typed("backing", "VirtualEthernetCardNetworkBackingInfo", [.text("deviceName", network)])
    }

    /// Changes an adapter's port group and/or connection state (works while the VM runs).
    public func setNetworkAdapter(vm: MoRef, adapter: NetworkAdapter, network: String, connected: Bool, startConnected: Bool) async throws {
        let device = XMLOut.Element.typed("device", adapter.deviceType, [
            .int("key", adapter.key),
            backing(network: network),
            connectable(connected: connected, startConnected: startConnected),
            .text("addressType", adapter.addressType),
            .text("macAddress", adapter.macAddress),
        ])
        let change = XMLOut.Element("deviceChange", children: [.text("operation", "edit"), device])
        try await runTask("ReconfigVM_Task", this: vm, [XMLOut.Element("spec", children: [change])])
    }

    /// Adds an adapter on a port group (hot-add on most guests).
    public func addNetworkAdapter(vm: MoRef, type: AdapterType, network: String, connected: Bool = true) async throws {
        let device = XMLOut.Element.typed("device", type.rawValue, [
            .int("key", -1),
            backing(network: network),
            connectable(connected: connected, startConnected: true),
            .text("addressType", "generated"),
        ])
        let change = XMLOut.Element("deviceChange", children: [.text("operation", "add"), device])
        try await runTask("ReconfigVM_Task", this: vm, [XMLOut.Element("spec", children: [change])])
    }

    /// Removes an adapter.
    public func removeNetworkAdapter(vm: MoRef, adapter: NetworkAdapter) async throws {
        let device = XMLOut.Element.typed("device", adapter.deviceType, [.int("key", adapter.key)])
        let change = XMLOut.Element("deviceChange", children: [.text("operation", "remove"), device])
        try await runTask("ReconfigVM_Task", this: vm, [XMLOut.Element("spec", children: [change])])
    }
}

// MARK: - Host networking (standard vSwitches and their port groups)

public struct VSwitch: Sendable, Hashable, Identifiable {
    public var name: String
    public var numPorts: Int
    public var uplinks: [String]          // vmnic0, vmnic1…
    public var portGroups: [String]       // names
    public var mtu: Int
    public var id: String { name }
}

public struct PhysicalNIC: Sendable, Hashable, Identifiable {
    public var device: String             // vmnic0
    public var mac: String
    public var linkMbps: Int?             // nil = link down
    public var id: String { device }
}

public struct HostNetworking: Sendable, Hashable {
    public var switches: [VSwitch]
    public var portGroups: [PortGroup]
    public var nics: [PhysicalNIC]
    /// vmnics not attached to any vSwitch.
    public var freeNICs: [PhysicalNIC] { nics.filter { n in !switches.contains { $0.uplinks.contains(n.device) } } }
}

extension VimSession {
    private func networkSystem() async throws -> MoRef {
        let hosts = try await retrieveAll(type: "HostSystem", paths: ["configManager.networkSystem"])
        guard let ns = hosts.first?.ref("configManager.networkSystem") else { throw VimError.malformedResponse("HostNetworkSystem") }
        return ns
    }

    /// Switches, port groups and physical NICs of the host.
    public func hostNetworking() async throws -> HostNetworking {
        let ns = try await networkSystem()
        let info = try await retrieveProperties(of: [ns], paths: ["networkInfo.vswitch", "networkInfo.portgroup", "networkInfo.pnic"])
        guard let o = info.first else { throw VimError.malformedResponse("networkInfo") }
        let nics = (o.props["networkInfo.pnic"]?.children ?? []).compactMap { n -> PhysicalNIC? in
            guard let dev = n.string("device") else { return nil }
            return PhysicalNIC(device: dev, mac: n.string("mac") ?? "", linkMbps: n["linkSpeed"]?.int("speedMb"))
        }.sorted { $0.device.localizedStandardCompare($1.device) == .orderedAscending }
        let groups = (o.props["networkInfo.portgroup"]?.children ?? []).compactMap { g -> PortGroup? in
            guard let spec = g["spec"], let name = spec.string("name") else { return nil }
            return PortGroup(name: name, vlanID: spec.int("vlanId") ?? 0, vSwitch: spec.string("vswitchName") ?? "")
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let switches = (o.props["networkInfo.vswitch"]?.children ?? []).compactMap { v -> VSwitch? in
            guard let name = v.string("name") else { return nil }
            // pnic keys look like key-vim.host.PhysicalNic-vmnic0; port group keys key-vim.host.PortGroup-<name>.
            let uplinks = v.all("pnic").map { $0.trimmedText.components(separatedBy: "PhysicalNic-").last ?? $0.trimmedText }
            let pgs = v.all("portgroup").map { $0.trimmedText.components(separatedBy: "PortGroup-").last ?? $0.trimmedText }
            return VSwitch(name: name, numPorts: v.int("numPorts") ?? 0, uplinks: uplinks, portGroups: pgs, mtu: v.int("mtu") ?? 1500)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return HostNetworking(switches: switches, portGroups: groups, nics: nics)
    }

    private func portGroupSpec(name: String, vlan: Int, vSwitch: String) -> XMLOut.Element {
        XMLOut.Element("portgrp", children: [
            .text("name", name), .int("vlanId", vlan), .text("vswitchName", vSwitch),
            XMLOut.Element("policy"),
        ])
    }

    /// Creates a port group on a standard vSwitch (VLAN 0 = none, 4095 = trunk).
    public func addPortGroup(name: String, vlan: Int, vSwitch: String) async throws {
        try await call("AddPortGroup", this: await networkSystem(), [portGroupSpec(name: name, vlan: vlan, vSwitch: vSwitch)])
    }

    /// Renames and/or re-VLANs a port group. VMs on it keep following it by name only when the
    /// name stays; a rename leaves their backing pointing at the old name.
    public func updatePortGroup(current: String, name: String, vlan: Int, vSwitch: String) async throws {
        try await call("UpdatePortGroup", this: await networkSystem(), [.text("pgName", current), portGroupSpec(name: name, vlan: vlan, vSwitch: vSwitch)])
    }

    public func removePortGroup(name: String) async throws {
        try await call("RemovePortGroup", this: await networkSystem(), [.text("pgName", name)])
    }

    /// Creates a standard vSwitch, optionally bonded to physical NICs.
    public func addVirtualSwitch(name: String, uplinks: [String], ports: Int = 128, mtu: Int = 1500) async throws {
        var spec: [XMLOut.Element] = [.int("numPorts", ports)]
        if !uplinks.isEmpty {
            spec.append(.typed("bridge", "HostVirtualSwitchBondBridge", uplinks.map { .text("nicDevice", $0) }))
        }
        spec.append(.int("mtu", mtu))
        try await call("AddVirtualSwitch", this: await networkSystem(), [.text("vswitchName", name), XMLOut.Element("spec", children: spec)])
    }

    /// Changes a vSwitch's uplinks (empty = none).
    public func setVirtualSwitchUplinks(name: String, uplinks: [String], ports: Int, mtu: Int) async throws {
        var spec: [XMLOut.Element] = [.int("numPorts", ports)]
        if !uplinks.isEmpty {
            spec.append(.typed("bridge", "HostVirtualSwitchBondBridge", uplinks.map { .text("nicDevice", $0) }))
        }
        spec.append(.int("mtu", mtu))
        try await call("UpdateVirtualSwitch", this: await networkSystem(), [.text("vswitchName", name), XMLOut.Element("spec", children: spec)])
    }

    public func removeVirtualSwitch(name: String) async throws {
        try await call("RemoveVirtualSwitch", this: await networkSystem(), [.text("vswitchName", name)])
    }
}
