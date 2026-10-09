import LabDockCore
import SwiftUI
import VimClient

/// Edit the VM's network adapters (Overview ▸ Network ▸ Edit…): move a card to another port
/// group, connect/disconnect, add or remove cards. The API lives in `VimClient/Networking.swift`
/// and was verified against a real ESXi host; this sheet is its UI.
struct NetworkAdaptersSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let host: HostModel
    let vm: VMSummary

    @State private var adapters: [NetworkAdapter] = []
    @State private var portGroups: [PortGroup] = []
    @State private var drafts: [Int: Draft] = [:]
    @State private var loading = true
    @State private var applying = false
    @State private var failure: String?
    @State private var confirmingRemoval: NetworkAdapter?
    @State private var newType: AdapterType = .vmxnet3

    /// What the user changed about one adapter.
    struct Draft {
        var network: String
        var connected: Bool
        var startConnected: Bool
        func changed(from original: NetworkAdapter) -> Bool {
            network != original.network || connected != original.connected || startConnected != original.startConnected
        }
    }

    var body: some View {
        QuietSheet(title: "Network adapters of \(vm.name)",
                   subtitle: subtitle,
                   width: 560,
                   failure: failure) {
            if loading {
                Text("Reading the adapters…").font(Theme.detail).foregroundStyle(Theme.faint)
            } else if adapters.isEmpty {
                Text("This VM has no network adapters.").font(Theme.detail).foregroundStyle(Theme.muted)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(adapters.enumerated()), id: \.element.id) { index, adapter in
                        adapterRow(adapter)
                            .padding(.vertical, 10)
                        if index < adapters.count - 1 {
                            Rectangle().fill(Theme.line).frame(height: 1)
                        }
                    }
                }
                addRow
                    .padding(.top, 14)
            }
        } actions: {
            if applying {
                Text("Applying…").font(Theme.caption).foregroundStyle(Theme.faint)
            }
            SheetButtons("Save changes",
                         disabled: !hasEdits || applying || loading,
                         action: save)
        }
        .task { await reload() }
        .confirmationDialog(
            "Remove \(confirmingRemoval?.label ?? "")?",
            isPresented: Binding(get: { confirmingRemoval != nil }, set: { if !$0 { confirmingRemoval = nil } }),
            titleVisibility: .visible,
            presenting: confirmingRemoval
        ) { adapter in
            Button("Remove adapter", role: .destructive) {
                remove(adapter)
                confirmingRemoval = nil
            }
            Button("Cancel", role: .cancel) { confirmingRemoval = nil }
        } message: { _ in
            Text("The guest loses this card and its network. This cannot be undone.")
        }
    }

    private var subtitle: String {
        var s = "Moves and connections apply right away when the guest takes them"
        if vm.powerState != .poweredOn { s = "The VM is off; the changes take effect at the next power on" }
        return s + "."
    }

    // MARK: Rows

    private func adapterRow(_ adapter: NetworkAdapter) -> some View {
        let draft = drafts[adapter.key] ?? Draft(network: adapter.network, connected: adapter.connected,
                                                 startConnected: adapter.startConnected)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(adapter.label).font(Theme.emphasis).foregroundStyle(Theme.ink)
                Text(adapter.typeWord).font(Theme.caption).foregroundStyle(Theme.faint)
                Spacer(minLength: 12)
                if !adapter.macAddress.isEmpty {
                    Text(adapter.macAddress).font(Theme.mono).foregroundStyle(Theme.faint)
                }
                Button("Remove…", role: .destructive) { confirmingRemoval = adapter }
                    .buttonStyle(.quietDestructive)
                    .font(Theme.caption)
                    .disabled(applying)
            }
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                SheetField("Port group") {
                    SheetPicker("Port group", selection: Binding(
                        get: { draft.network },
                        set: { drafts[adapter.key] = Draft(network: $0, connected: draft.connected, startConnected: draft.startConnected) }
                    ), maxWidth: 280) {
                        // An empty name means a backing LabDock can't name (a distributed
                        // switch): keep it selectable so Save never rewrites it by accident.
                        if adapter.network.isEmpty || portGroups.isEmpty {
                            Text("—").tag("")
                        }
                        ForEach(portGroups) { group in
                            Text(group.vlanID == 0 ? "\(group.name) — VLAN 0" : "\(group.name) — VLAN \(group.vlanID)")
                                .tag(group.name)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    SheetToggle("Connected", isOn: Binding(
                        get: { draft.connected },
                        set: { drafts[adapter.key] = Draft(network: draft.network, connected: $0, startConnected: draft.startConnected) }
                    ))
                    SheetToggle("Connect at power on", isOn: Binding(
                        get: { draft.startConnected },
                        set: { drafts[adapter.key] = Draft(network: draft.network, connected: draft.connected, startConnected: $0) }
                    ))
                }
            }
            if draft.changed(from: adapter) {
                Text("Changed — saved with Save changes").font(Theme.caption).foregroundStyle(Theme.muted)
            }
        }
    }

    private var addRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            SheetField("Add an adapter") {
                SheetPicker("Type", selection: $newType, maxWidth: 280) {
                    ForEach(AdapterType.allCases, id: \.self) { type in
                        Text(type.title).tag(type)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("It lands on the VM's first port group; move it with Edit afterwards.")
                    .font(Theme.caption).foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Add adapter") { add() }
                    .buttonStyle(.quietLink)
                    .disabled(applying || loading || portGroups.isEmpty)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Actions

    private var hasEdits: Bool {
        adapters.contains { a in (drafts[a.key] ?? Draft(network: a.network, connected: a.connected, startConnected: a.startConnected)).changed(from: a) }
    }

    private func reload() async {
        loading = true
        failure = nil
        do {
            let session = try host.sessionForGuest()
            async let groups = session.portGroups()
            async let cards = session.networkAdapters(vm: vm.ref)
            portGroups = try await groups
            adapters = try await cards
            drafts = [:]
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        loading = false
    }

    private func save() {
        applying = true
        failure = nil
        Task {
            do {
                let session = try host.sessionForGuest()
                for adapter in adapters {
                    let draft = drafts[adapter.key] ?? Draft(network: adapter.network, connected: adapter.connected,
                                                             startConnected: adapter.startConnected)
                    guard draft.changed(from: adapter) else { continue }
                    try await session.setNetworkAdapter(vm: vm.ref, adapter: adapter,
                                                        network: draft.network, connected: draft.connected,
                                                        startConnected: draft.startConnected)
                }
                host.refreshNow()
                model.refreshDetail()
                await reload()
            } catch {
                failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            applying = false
        }
    }

    private func add() {
        applying = true
        failure = nil
        Task {
            do {
                let session = try host.sessionForGuest()
                try await session.addNetworkAdapter(vm: vm.ref, type: newType,
                                                    network: portGroups.first?.name ?? "")
                host.refreshNow()
                model.refreshDetail()
                await reload()
            } catch {
                failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            applying = false
        }
    }

    private func remove(_ adapter: NetworkAdapter) {
        applying = true
        failure = nil
        Task {
            do {
                let session = try host.sessionForGuest()
                try await session.removeNetworkAdapter(vm: vm.ref, adapter: adapter)
                host.refreshNow()
                model.refreshDetail()
                await reload()
            } catch {
                failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            applying = false
        }
    }
}
