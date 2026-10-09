import LabDockCore
import SwiftUI
import VimClient

/// The snapshot tree (indent, "· current", created date) with Take snapshot above it and
/// Revert / Delete / Delete all as words. Confirmations are sentences.
struct SnapshotsView: View {
    @Environment(AppModel.self) private var model
    let host: HostModel
    let vm: VMSummary
    @State private var name = ""
    @State private var descriptionText = ""
    @State private var includeMemory = true
    @State private var quiesce = false
    /// The row the user clicked. Resolved against the live tree through `selection`, so a node
    /// that was deleted (or belongs to the VM shown before) never drives an action.
    @State private var selected: SnapshotNode?
    @State private var confirming: Confirm?

    enum Confirm: Identifiable {
        case revert(SnapshotNode)
        case delete(SnapshotNode)
        case deleteAll
        var id: String {
            switch self {
            case .revert(let n): return "revert:\(n.id)"
            case .delete(let n): return "delete:\(n.id)"
            case .deleteAll: return "deleteAll"
            }
        }
    }

    private var busy: Bool { host.busyVMs.contains(vm.ref.value) }

    /// The selected node as it stands in `vm.snapshots` now; nil once it is gone.
    private var selection: SnapshotNode? {
        guard let selected else { return nil }
        return vm.snapshots.lazy.flatMap { $0.flattened() }.first { $0.node.ref == selected.ref }?.node
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ActionErrorLine(text: host.actionError(vm: vm))
                QuietSection(title: "Take snapshot", trailing: {
                    HStack(spacing: 16) {
                        Button("Take snapshot") { take() }
                            .buttonStyle(.quietLink)
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || busy || !reachable)
                    }
                }) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline, spacing: 16) {
                            QuietTextField("Name", text: $name, prompt: "before the upgrade")
                                .textFieldStyle(.quiet)
                            QuietTextField("Description", text: $descriptionText, prompt: "what this snapshot is for")
                                .textFieldStyle(.quiet)
                        }
                        HStack(spacing: 32) {
                            Toggle("Include memory", isOn: $includeMemory).toggleStyle(.quiet)
                                .disabled(vm.powerState != .poweredOn)
                            Toggle("Quiesce the guest file system", isOn: $quiesce).toggleStyle(.quiet)
                                .disabled(!vm.tools.isRunning || vm.powerState != .poweredOn)
                            if vm.powerState != .poweredOn, includeMemory {
                                Text("The VM is off; the snapshot will not include memory.")
                                    .font(Theme.caption).foregroundStyle(Theme.faint)
                            } else if vm.powerState == .poweredOn, quiesce, !vm.tools.isRunning {
                                Text("Tools isn't running; the file system will not be quiesced.")
                                    .font(Theme.caption).foregroundStyle(Theme.faint)
                            }
                        }
                        .font(Theme.detail)
                    }
                }
                .padding(.bottom, 26)

                QuietSection(title: "Snapshots", trailing: {
                    HStack(spacing: 16) {
                        Button("Revert to selected") {
                            if let s = selection { confirming = .revert(s) }
                        }
                        .buttonStyle(.quietLink)
                        .disabled(selection == nil || busy || !reachable)
                        Button("Delete selected", role: .destructive) {
                            if let s = selection { confirming = .delete(s) }
                        }
                        .buttonStyle(.quietDestructive)
                        .disabled(selection == nil || busy || !reachable)
                        Button("Delete all", role: .destructive) { confirming = .deleteAll }
                            .buttonStyle(.quietDestructive)
                            .disabled(vm.snapshots.isEmpty || busy || !reachable)
                    }
                }) {
                    if vm.snapshots.isEmpty {
                        QuietNote("No snapshots yet.")
                    } else {
                        tree
                    }
                }
            }
            .padding(EdgeInsets(top: 28, leading: 40, bottom: 24, trailing: 40))
            .frame(maxWidth: 1200, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: vm.ref) { _, _ in
            // Another VM: nothing typed or picked for the last one applies here.
            selected = nil
            confirming = nil
            name = ""
            descriptionText = ""
        }
        .confirmationDialog(
            confirming.map { title($0) } ?? "",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible,
            presenting: confirming
        ) { action in
            let role: ButtonRole? = switch action {
            case .revert: nil
            case .delete, .deleteAll: .destructive
            }
            Button(buttonTitle(action), role: role) {
                Task {
                    switch action {
                    case .revert(let s): await host.revert(to: s.ref, vm: vm)
                    case .delete(let s): await host.deleteSnapshot(s.ref, children: false, vm: vm)
                    case .deleteAll: await host.deleteAllSnapshots(vm: vm)
                    }
                    selected = nil
                }
                confirming = nil
            }
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: { action in
            Text(message(action))
        }
    }

    private var reachable: Bool {
        if case .connected = host.phase { return true }
        return false
    }

    private var tree: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(vm.snapshots) { root in
                SnapshotRows(root: root, depth: 0, current: vm.currentSnapshot, selected: selection) { selected = $0 }
            }
        }
    }

    private func take() {
        // ESXi refuses a memory snapshot of a VM that isn't running, and quiescing needs Tools in
        // the guest: send only what the host can honour.
        let memory = includeMemory && vm.powerState == .poweredOn
        let quiesce = quiesce && vm.tools.isRunning && vm.powerState == .poweredOn
        Task {
            await host.takeSnapshot(name: name.trimmingCharacters(in: .whitespaces),
                                    description: descriptionText, memory: memory, quiesce: quiesce, vm: vm)
            name = ""
            descriptionText = ""
        }
    }

    private func title(_ action: Confirm) -> String {
        switch action {
        case .revert(let s): return "Revert to \(s.name)?"
        case .delete(let s): return "Delete \(s.name)?"
        case .deleteAll: return "Delete every snapshot of \(vm.name)?"
        }
    }

    private func buttonTitle(_ action: Confirm) -> String {
        switch action {
        case .revert: return "Revert"
        case .delete: return "Delete"
        case .deleteAll: return "Delete all"
        }
    }

    private func message(_ action: Confirm) -> String {
        switch action {
        case .revert(let s):
            return s.powerState == .suspended
                ? "The VM returns to the suspended state it was in when the snapshot was taken."
                : "The VM returns to the moment the snapshot was taken; everything since is lost."
        case .delete(let s):
            return s.children.isEmpty
                ? "The disk changes it holds are merged away. This cannot be undone."
                : "Its child snapshots are kept."
        case .deleteAll:
            return "Every snapshot of this VM goes away, and the disks consolidate. This cannot be undone."
        }
    }
}

/// The recursive rows of the snapshot tree.
struct SnapshotRows: View {
    let root: SnapshotNode
    let depth: Int
    let current: MoRef?
    let selected: SnapshotNode?
    let select: (SnapshotNode) -> Void

    var body: some View {
        QuietRow {
            row
        }
        ForEach(root.children) { child in
            SnapshotRows(root: child, depth: depth + 1, current: current, selected: selected, select: select)
        }
    }

    private var isCurrent: Bool { root.ref == current }
    private var isSelected: Bool { selected?.id == root.id }

    private var row: some View {
        Button { select(root) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(root.name)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(Theme.ink)
                if isCurrent { Text("· current").font(Theme.detail).foregroundStyle(Theme.on) }
                Spacer(minLength: 12)
                if let created = root.created {
                    Text(created.formatted(date: .abbreviated, time: .shortened))
                        .font(Theme.caption.monospacedDigit())
                        .foregroundStyle(Theme.faint)
                }
                if root.powerState == .poweredOn {
                    Text("· memory included")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.faint)
                }
            }
            .padding(.leading, CGFloat(depth) * 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
