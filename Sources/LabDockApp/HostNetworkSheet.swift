import LabDockCore
import SwiftUI
import VimClient

/// The host's standard vSwitches and port groups (Overview ▸ Network ▸ Host networking…, or the
/// host's context menu in the sidebar): change a port group's VLAN, add or remove port groups,
/// add a vSwitch on free physical NICs, remove an empty one. Every change applies at once and
/// the list reloads; a refusal from ESXi is a sentence under the list.
struct HostNetworkSheet: View {
    @Environment(\.dismiss) private var dismiss
    let host: HostModel

    @State private var net: HostNetworking?
    @State private var failure: String?
    @State private var busy = false
    /// VLAN edits in flight, by port group name.
    @State private var vlanDrafts: [String: String] = [:]
    @State private var newGroupName: [String: String] = [:]   // by vSwitch
    @State private var newGroupVLAN: [String: String] = [:]
    @State private var newSwitchName = ""
    @State private var newSwitchUplinks: Set<String> = []
    @State private var confirmingRemoval: Removal?

    enum Removal: Identifiable {
        case portGroup(String), vSwitch(String)
        var id: String {
            switch self {
            case .portGroup(let n): "pg:\(n)"
            case .vSwitch(let n): "vs:\(n)"
            }
        }
        var title: String {
            switch self {
            case .portGroup(let n): "Remove port group \(n)?"
            case .vSwitch(let n): "Remove vSwitch \(n)?"
            }
        }
    }

    var body: some View {
        QuietSheet(title: "Networking on \(host.address)",
                   subtitle: "Standard vSwitches and their port groups. Changes apply right away; VMs on a port group keep it by name.",
                   width: 620, failure: failure) {
            if let net {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(net.switches) { sw in
                        switchSection(sw, net: net)
                    }
                    addSwitchSection(net)
                }
            } else {
                Text("Reading the host's networking…").font(Theme.detail).foregroundStyle(Theme.faint)
            }
        } actions: {
            if busy { Text("Applying…").font(Theme.caption).foregroundStyle(Theme.faint) }
            SheetButtons("Done", cancelTitle: "", action: { dismiss() })
        }
        .task { await reload() }
        .confirmationDialog(confirmingRemoval?.title ?? "", isPresented: Binding(get: { confirmingRemoval != nil }, set: { if !$0 { confirmingRemoval = nil } }),
                            titleVisibility: .visible, presenting: confirmingRemoval) { removal in
            Button("Remove", role: .destructive) { perform(removal); confirmingRemoval = nil }
            Button("Cancel", role: .cancel) { confirmingRemoval = nil }
        } message: { removal in
            switch removal {
            case .portGroup: Text("Adapters on this port group lose their network until they are moved.")
            case .vSwitch: Text("The switch must have no port groups; its uplinks become free.")
            }
        }
    }

    // MARK: Sections

    private func switchSection(_ sw: VSwitch, net: HostNetworking) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(sw.name).font(Theme.emphasis).foregroundStyle(Theme.ink)
                Text(sw.uplinks.isEmpty ? "no uplink (internal only)" : "uplink " + sw.uplinks.joined(separator: ", "))
                    .font(Theme.caption).foregroundStyle(sw.uplinks.isEmpty ? Theme.paused : Theme.muted)
                Text("MTU \(sw.mtu)").font(Theme.caption).foregroundStyle(Theme.faint)
                Spacer(minLength: 8)
                if sw.portGroups.isEmpty {
                    Button("Remove switch…", role: .destructive) { confirmingRemoval = .vSwitch(sw.name) }
                        .buttonStyle(.quietDestructive).font(Theme.caption).disabled(busy)
                }
            }
            uplinkRow(sw, net: net)
            ForEach(net.portGroups.filter { $0.vSwitch == sw.name }) { pg in
                portGroupRow(pg)
            }
            addGroupRow(sw)
        }
    }

    /// Uplinks as toggles over the host's NICs: on = bonded to this switch.
    private func uplinkRow(_ sw: VSwitch, net: HostNetworking) -> some View {
        HStack(spacing: 14) {
            Text("Uplinks").font(Theme.caption).foregroundStyle(Theme.muted).frame(width: 90, alignment: .leading)
            ForEach(net.nics) { nic in
                let onThis = sw.uplinks.contains(nic.device)
                let elsewhere = !onThis && net.switches.contains { $0.uplinks.contains(nic.device) }
                SheetToggle(nic.linkMbps.map { "\(nic.device) · \($0) Mb" } ?? "\(nic.device) · down", isOn: Binding(
                    get: { onThis },
                    set: { on in
                        var links = sw.uplinks
                        if on { links.append(nic.device) } else { links.removeAll { $0 == nic.device } }
                        run { try await $0.setVirtualSwitchUplinks(name: sw.name, uplinks: links, ports: sw.numPorts, mtu: sw.mtu) }
                    }))
                .disabled(busy || elsewhere)
                .help(elsewhere ? "\(nic.device) is the uplink of another switch" : "")
            }
        }
    }

    private func portGroupRow(_ pg: PortGroup) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(pg.name).font(Theme.body).foregroundStyle(Theme.ink).frame(minWidth: 90, alignment: .leading)
            Text("VLAN").font(Theme.caption).foregroundStyle(Theme.muted)
            TextField("VLAN", text: Binding(get: { vlanDrafts[pg.name] ?? String(pg.vlanID) }, set: { vlanDrafts[pg.name] = $0 }),
                      prompt: Text(verbatim: ""))
                .textFieldStyle(.quietMonospaced)
                .frame(width: 64)
                .onSubmit { applyVLAN(pg) }
            if let draft = vlanDrafts[pg.name], draft != String(pg.vlanID) {
                Button("Apply") { applyVLAN(pg) }.buttonStyle(.quietLink).font(Theme.caption).disabled(busy)
            }
            Text(vlanWord(pg.vlanID)).font(Theme.caption).foregroundStyle(Theme.faint)
            Spacer(minLength: 8)
            Button("Remove…", role: .destructive) { confirmingRemoval = .portGroup(pg.name) }
                .buttonStyle(.quietDestructive).font(Theme.caption).disabled(busy)
        }
        .padding(.leading, 12)
    }

    private func vlanWord(_ id: Int) -> String {
        switch id {
        case 0: "untagged"
        case 4095: "trunk (all VLANs)"
        default: "tagged"
        }
    }

    private func addGroupRow(_ sw: VSwitch) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text("Add port group").font(Theme.caption).foregroundStyle(Theme.muted)
            TextField("Name", text: Binding(get: { newGroupName[sw.name] ?? "" }, set: { newGroupName[sw.name] = $0 }), prompt: Text(verbatim: ""))
                .textFieldStyle(.quiet).frame(width: 160)
            Text("VLAN").font(Theme.caption).foregroundStyle(Theme.muted)
            TextField("VLAN", text: Binding(get: { newGroupVLAN[sw.name] ?? "0" }, set: { newGroupVLAN[sw.name] = $0 }), prompt: Text(verbatim: ""))
                .textFieldStyle(.quietMonospaced).frame(width: 64)
            Button("Add") {
                let name = (newGroupName[sw.name] ?? "").trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, let vlan = Int(newGroupVLAN[sw.name] ?? "0"), (0...4095).contains(vlan) else {
                    failure = "A port group needs a name and a VLAN between 0 and 4095."; return
                }
                run {
                    try await $0.addPortGroup(name: name, vlan: vlan, vSwitch: sw.name)
                    newGroupName[sw.name] = ""; newGroupVLAN[sw.name] = "0"
                }
            }
            .buttonStyle(.quietLink).font(Theme.caption).disabled(busy)
        }
        .padding(.leading, 12)
    }

    private func addSwitchSection(_ net: HostNetworking) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("New vSwitch").font(Theme.emphasis).foregroundStyle(Theme.ink)
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                TextField("Name", text: $newSwitchName, prompt: Text(verbatim: "")).textFieldStyle(.quiet).frame(width: 160)
                Text("Uplinks").font(Theme.caption).foregroundStyle(Theme.muted)
                if net.freeNICs.isEmpty {
                    Text("none free (internal-only switch)").font(Theme.caption).foregroundStyle(Theme.faint)
                }
                ForEach(net.freeNICs) { nic in
                    SheetToggle(nic.device, isOn: Binding(get: { newSwitchUplinks.contains(nic.device) },
                                                          set: { if $0 { newSwitchUplinks.insert(nic.device) } else { newSwitchUplinks.remove(nic.device) } }))
                }
                Button("Create") {
                    let name = newSwitchName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { failure = "The switch needs a name."; return }
                    run {
                        try await $0.addVirtualSwitch(name: name, uplinks: Array(newSwitchUplinks).sorted())
                        newSwitchName = ""; newSwitchUplinks = []
                    }
                }
                .buttonStyle(.quietLink).font(Theme.caption).disabled(busy)
            }
        }
    }

    // MARK: Actions

    private func applyVLAN(_ pg: PortGroup) {
        guard let text = vlanDrafts[pg.name], let vlan = Int(text), (0...4095).contains(vlan) else {
            failure = "VLAN must be a number between 0 and 4095 (4095 = trunk)."; return
        }
        guard vlan != pg.vlanID else { vlanDrafts[pg.name] = nil; return }
        run {
            try await $0.updatePortGroup(current: pg.name, name: pg.name, vlan: vlan, vSwitch: pg.vSwitch)
            vlanDrafts[pg.name] = nil
        }
    }

    private func perform(_ removal: Removal) {
        switch removal {
        case .portGroup(let name): run { try await $0.removePortGroup(name: name) }
        case .vSwitch(let name): run { try await $0.removeVirtualSwitch(name: name) }
        }
    }

    private func run(_ action: @escaping @MainActor (VimSession) async throws -> Void) {
        busy = true
        failure = nil
        Task {
            defer { busy = false }
            do {
                let session = try host.sessionForGuest()
                try await action(session)
                await reload()
                host.refreshNow()
            } catch {
                failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func reload() async {
        do {
            net = try await host.sessionForGuest().hostNetworking()
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
