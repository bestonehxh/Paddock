import LabDockCore
import SwiftUI
import VimClient

/// Key/value rows: power since, CPU, memory, disks, network, guest OS, Tools, guest login,
/// current snapshot. Values come from the polled summary plus the selected VM's detail.
struct OverviewView: View {
    @Environment(AppModel.self) private var model
    let host: HostModel
    let vm: VMSummary
    @State private var showingGuestLogin = false
    @State private var showingNetwork = false
    @State private var showingHostNetwork = false
    /// VMware's "lock the guest when the last remote user disconnects" (tools.guest.desktop.autolock).
    @State private var autolock: Bool?
    @State private var autolockLoaded = false
    @State private var autolockBusy = false
    @State private var autolockError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // The last Power / Tools action that failed on this VM (owner, 3 Oct 2026: shown
                // here and on Snapshots only, not under the bar on every tab).
                ActionErrorLine(text: host.actionError(vm: vm))
                if vm.inaccessible {
                    Text("ESXi can't open this virtual machine (\(vm.connectionState)). Its files or datastore are missing; remove it from the host's inventory or restore the datastore.")
                        .font(Theme.detail).foregroundStyle(Theme.attention)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 14)
                }
                if let why = model.detailError {
                    Text("Couldn't read the hardware: \(why)")
                        .font(Theme.detail).foregroundStyle(Theme.attention)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 14)
                }
                rows
            }
            .padding(EdgeInsets(top: 28, leading: 40, bottom: 24, trailing: 40))
            .frame(maxWidth: 1200, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showingGuestLogin) {
            GuestLoginSheet(host: host, vm: vm)
        }
        .sheet(isPresented: $showingNetwork) {
            NetworkAdaptersSheet(host: host, vm: vm)
        }
        .sheet(isPresented: $showingHostNetwork) {
            HostNetworkSheet(host: host)
        }
    }

    @ViewBuilder private var rows: some View {
        QuietRow(first: true) { row("Power") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StateChip(text: vm.stateWord,
                          tint: vm.inaccessible ? Theme.faint : Theme.tint(vm.powerState))
                if !powerSinceTail.isEmpty {
                    Text(powerSinceTail)
                }
            }
        } }
        QuietRow { row("CPU", "\(vm.numCPU) vCPU\(usageCPU)") }
        QuietRow { row("Memory", "\(gigabytes(Int64(vm.memoryMB) * 1_048_576))\(usageMemory)") }
        if !disks.isEmpty { QuietRow { row("Disks", disks) } }
        QuietRow { row("Network") { networkValue } }
        QuietRow { row("Guest OS", guestLine) }
        if let ips, !ips.isEmpty { QuietRow { row("IP addresses", ips.joined(separator: ", ")) } }
        QuietRow { row("VMware Tools") {
            VStack(alignment: .leading, spacing: 6) {
                StateChip(text: vm.tools.word, tint: Theme.tint(vm.tools))
                if vm.powerState == .poweredOn && !vm.tools.isRunning {
                    ToolsInstallHint(host: host, vm: vm)
                }
            }
        } }
        QuietRow { row("Guest login") { guestLoginValue } }
        QuietRow { row("Current snapshot", currentSnapshot) }
        QuietRow { row("Console lock") { autolockValue } }
        if let vmx = vm.vmxPath { QuietRow { row("Configuration", vmx) } }
    }

    /// The network cards as a line, with Edit… beside them (the sheet reconfigures them).
    private var networkValue: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if nics.isEmpty {
                Text("—")
            } else {
                Text(nics)
            }
            Button("Edit…") { showingNetwork = true }
                .buttonStyle(.quietLink)
                .font(Theme.detail)
                .disabled(vm.inaccessible || !reachable)
            Button("Host networking…") { showingHostNetwork = true }
                .buttonStyle(.quietLink)
                .font(Theme.detail)
                .disabled(!reachable)
        }
    }

    private func row(_ key: String, _ value: String) -> some View {
        row(key) { Text(value) }
    }

    private func row<Value: View>(_ key: String, @ViewBuilder _ value: () -> Value) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(key)
                .font(Theme.detail)
                .foregroundStyle(Theme.muted)
                .frame(width: 140, alignment: .leading)
            value()
                .font(Theme.detail)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// The VM option that locks Windows every time the last console goes away (owner found it the
    /// hard way, 3 Oct 2026; ESXi sets it on new VMs).
    private var autolockValue: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if !autolockLoaded {
                Text("reading…").foregroundStyle(Theme.faint)
            } else {
                Text(autolock == true ? "locks the guest when the last console disconnects" : (autolock == false ? "the guest stays as it is when consoles disconnect" : "not set (host default)"))
                    .foregroundStyle(autolock == true ? Theme.paused : Theme.ink)
                Button(autolock == true ? "Turn off" : "Turn on") { setAutolock(!(autolock ?? false)) }
                    .buttonStyle(.quietLink)
                    .font(Theme.detail)
                    .disabled(autolockBusy || !reachable || vm.inaccessible)
            }
            if let autolockError {
                Text(autolockError).foregroundStyle(Theme.attention)
            }
        }
        .task(id: vm.ref) {
            autolockLoaded = false
            autolock = try? await host.sessionForGuest().autolock(vm: vm.ref)
            autolockLoaded = true
        }
    }

    private func setAutolock(_ on: Bool) {
        autolockBusy = true
        autolockError = nil
        Task {
            defer { autolockBusy = false }
            do {
                let session = try host.sessionForGuest()
                try await session.setAutolock(vm: vm.ref, on)
                autolock = try await session.autolock(vm: vm.ref)
            } catch {
                autolockError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private var guestLoginValue: some View {
        HStack(spacing: 10) {
            if host.hasGuestLogin(vm: vm), let user = host.guestUser(vm: vm) {
                Text("\(user) · saved in Keychain")
                Button("Change") { showingGuestLogin = true }
                    .buttonStyle(.quietLink)
                    .font(Theme.detail)
            } else if host.hasGuestLogin(vm: vm) {
                Text("saved, but the Keychain didn't let LabDock read it; click Allow when macOS asks").foregroundStyle(Theme.attention)
                Button("Change") { showingGuestLogin = true }
                    .buttonStyle(.quietLink)
                    .font(Theme.detail)
            } else {
                Text("not saved")
                Button("Add") { showingGuestLogin = true }
                    .buttonStyle(.quietLink)
                    .font(Theme.detail)
            }
        }
    }

    /// " since 21 Sep at 15:59 (11 d 23 h)" after the tinted state word.
    private var powerSinceTail: String {
        guard vm.powerState == .poweredOn, let boot = vm.bootTime else { return "" }
        let since = Date().timeIntervalSince(boot)
        return " since \(boot.formatted(date: .abbreviated, time: .shortened)) (\(durationWords(since)))"
    }

    /// "Microsoft Windows 11 (64-bit) · hostname WIN11-LAB".
    private var guestLine: String {
        var s = vm.guestFullName ?? vm.guestId ?? "—"
        if let h = vm.hostName { s += " · hostname \(h)" }
        return s
    }

    private var usageCPU: String {
        guard let mhz = vm.cpuUsageMHz, vm.numCPU > 0, vm.powerState == .poweredOn else { return "" }
        return " · using \(mhz) MHz"
    }

    private var reachable: Bool {
        if case .connected = host.phase { return true }
        return false
    }

    private var usageMemory: String {
        guard let mb = vm.guestMemoryUsageMB, vm.powerState == .poweredOn else { return "" }
        return " · guest using \(gigabytes(Int64(mb) * 1_048_576))"
    }

    private var ips: [String]? { model.detail?.ipAddresses.isEmpty == false ? model.detail?.ipAddresses : vm.ipAddress.map { [$0] } }

    private var disks: String {
        (model.detail?.disks ?? []).map { d in
            var s = "\(d.label): \(gigabytes(d.capacityBytes)) \(d.thin ? "thin" : "thick")"
            if let ds = d.fileName.split(separator: "]").first, d.fileName.hasPrefix("[") { s += " on \(ds.dropFirst())" }
            return s
        }.joined(separator: " · ")
    }

    private var nics: String {
        (model.detail?.nics ?? []).map { n in
            var s = "\(n.label): \(n.network)"
            if !n.macAddress.isEmpty { s += " (\(n.macAddress))" }
            if !n.connected, vm.powerState == .poweredOn { s += ", disconnected" }
            return s
        }.joined(separator: " · ")
    }

    private var currentSnapshot: String {
        guard let current = vm.currentSnapshot else { return "—" }
        func find(_ nodes: [SnapshotNode]) -> SnapshotNode? {
            for n in nodes {
                if n.ref == current { return n }
                if let hit = find(n.children) { return hit }
            }
            return nil
        }
        guard let node = find(vm.snapshots) else { return "—" }
        var s = node.name
        if let created = node.created {
            s += " · \(created.formatted(date: .abbreviated, time: .shortened))"
        }
        return s
    }

    /// Binary gigabytes, as the ESXi UI shows them (8192 MB → 8 GB).
    private func gigabytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / Double(1 << 30)
        return gb >= 10 ? String(format: "%.0f GB", gb) : String(format: "%.1f GB", gb)
    }

    private func durationWords(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds)) s" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) h \(Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)) min" }
        return "\(Int(seconds / 86_400)) d \(Int((seconds.truncatingRemainder(dividingBy: 86_400)) / 3600)) h"
    }
}

/// Adding or changing the guest login of one VM (user + password → Keychain).
struct GuestLoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    let host: HostModel
    let vm: VMSummary
    @State private var user = ""
    @State private var password = ""
    @State private var failure: String?

    var body: some View {
        QuietSheet(title: "Guest login for \(vm.name)",
                   subtitle: "Used for files, running commands and pasting into the guest. Saved in the Keychain.",
                   failure: failure) {
            SheetField("User") {
                QuietTextField("User", text: $user, prompt: vm.guestFamily == .windows ? "Administrator" : "root")
            }
            SheetField("Password", note: "LabDock stores it in the Keychain and nowhere else.") {
                QuietTextField("Password", text: $password, prompt: "", secure: true)
            }
        } actions: {
            SheetButtons("Save", disabled: user.isEmpty || password.isEmpty, action: {
                do {
                    try host.saveGuestLogin(user: user, password: password, vm: vm)
                    dismiss()
                } catch {
                    failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            })
        }
        .onAppear {
            user = host.guestUser(vm: vm) ?? ""
        }
    }
}
