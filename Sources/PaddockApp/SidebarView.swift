import PaddockCore
import SwiftUI
import VimClient

/// The sidebar: "Hosts", the filter words, then each host with its address, "45 VMs, 7 running ·
/// 8.0.2", a muted-red line when it's down, and its VMs (name left, state chip right; the
/// selected row sits in an accent capsule). Clicking a host folds or unfolds its list; a
/// double-click on a VM opens its console. "Add host…" sits at the bottom.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var showingAddHost: Bool
    @State private var confirmingRemoval: HostModel?
    @State private var showingTrust = false
    @State private var trustHost: HostModel?
    @State private var networkingHost: HostModel?
    /// Hosts whose VM list is folded (by address).
    @State private var collapsed: Set<String> = []

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            Text("Hosts")
                .font(Theme.caption)
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(Theme.faint)
                .padding(.bottom, 10)
            FilterWords(selection: $model.filter)
                .padding(.bottom, 14)
            if let storeError = model.storeError {
                Text(storeError)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.attention)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 12)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.hosts) { host in
                        HostSection(host: host,
                                    collapsed: collapsed.contains(host.address),
                                    onToggle: { toggle(host) },
                                    onTrust: { trustHost = host; showingTrust = true },
                                    onRemove: { confirmingRemoval = host },
                                    onNetworking: { networkingHost = host })
                    }
                }
                .padding(.trailing, 12)   // clear of the scroll indicator
            }
            .scrollBounceBehavior(.basedOnSize)
            .defaultScrollAnchor(.top)
            Spacer(minLength: 16)
            Button("Add host…") { showingAddHost = true }
                .buttonStyle(.quietLink)
                .font(Theme.body)
        }
        .padding(.top, model.windowFullScreen ? 12 : 30)   // under the traffic lights; higher in full screen
        .padding(.leading, 24)
        .padding(.trailing, 4)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .confirmationDialog(
            "Remove \(confirmingRemoval?.address ?? "")?",
            isPresented: Binding(get: { confirmingRemoval != nil }, set: { if !$0 { confirmingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove host", role: .destructive) {
                if let host = confirmingRemoval { model.removeHost(host) }
                confirmingRemoval = nil
            }
            Button("Cancel", role: .cancel) { confirmingRemoval = nil }
        } message: {
            Text("Paddock forgets the host and its saved guest logins. The virtual machines stay on the host.")
        }
        .sheet(isPresented: $showingTrust) {
            if let host = trustHost {
                TrustSheet(host: host)
            }
        }
        .sheet(item: $networkingHost) { host in
            HostNetworkSheet(host: host)
        }
    }

    private func toggle(_ host: HostModel) {
        withAnimation(.easeOut(duration: 0.15)) {
            if collapsed.contains(host.address) { collapsed.remove(host.address) } else { collapsed.insert(host.address) }
        }
    }
}

/// "All · Running · Off" as a small native segmented control (Look A).
struct FilterWords: View {
    @Binding var selection: AppModel.VMFilter

    var body: some View {
        Picker("Filter", selection: $selection) {
            ForEach(AppModel.VMFilter.allCases, id: \.self) { f in
                Text(f.title).tag(f)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
        .labelsHidden()
        .fixedSize()
    }
}

/// One host: the address line (click folds the list), the state line, its VM rows.
struct HostSection: View {
    @Environment(AppModel.self) private var model
    let host: HostModel
    let collapsed: Bool
    let onToggle: () -> Void
    let onTrust: () -> Void
    let onRemove: () -> Void
    var onNetworking: () -> Void = {}

    /// The filter applied; VMs ESXi can't open sink to the bottom so the real ones come first.
    private var shownVMs: [VMSummary] {
        let shown = host.vms.filter { model.filter.matches($0) }
        return shown.filter { !$0.inaccessible } + shown.filter { $0.inaccessible }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                hostHeader.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 6)
            .accessibilityLabel("\(host.address), \(collapsed ? "folded" : "unfolded")")
            if !collapsed {
                ForEach(shownVMs) { vm in
                    VMRow(host: host, vm: vm)
                }
                if shownVMs.isEmpty, !host.vms.isEmpty {
                    Text(model.filter == .running ? "none running" : "none off")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.faint)
                        .padding(.leading, 10)
                        .padding(.vertical, 4)
                }
            }
        }
        .padding(.bottom, 18)
        .contextMenu {
            Button(collapsed ? "Show virtual machines" : "Hide virtual machines") { onToggle() }
            Button("Refresh now") { host.refreshNow() }
            Button("Host networking…") { onNetworking() }
            if case .needsTrust = host.phase {
                Button("Review the new certificate…") { onTrust() }
            }
            Divider()
            Button("Remove host…", role: .destructive) { onRemove() }
        }
    }

    @ViewBuilder private var hostHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(collapsed ? "▸" : "▾")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 10)
                Text(host.address)
                    .font(Theme.body.weight(.medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                if case .connecting = host.phase {
                    Text("connecting…").font(Theme.caption).foregroundStyle(Theme.faint)
                }
            }
            Group {
                switch host.phase {
                case .connecting, .connected:
                    Text(host.subtitle).font(Theme.caption).foregroundStyle(Theme.faint)
                case .failed(let why):
                    Text([why, host.lastSeenLine].compactMap { $0 }.joined(separator: " · "))
                        .font(Theme.caption).foregroundStyle(Theme.attention).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                case .needsTrust:
                    Text("The host's certificate changed").font(Theme.caption).foregroundStyle(Theme.attention)
                }
            }
            .padding(.leading, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One VM row: name left, state chip right; the selected row sits in an accent capsule
/// (Finder's selection, Look A). One click selects, a double-click opens the console.
struct VMRow: View {
    @Environment(AppModel.self) private var model
    let host: HostModel
    let vm: VMSummary

    private var selected: Bool {
        model.selection?.host == host.address && model.selection?.vm == vm.ref.value
    }

    @State private var hovering = false
    @State private var showName = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(vm.name)
                .font(.system(size: 13, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? Color.white : (vm.inaccessible ? Theme.faint : Theme.muted))
                .lineLimit(1)
            Spacer(minLength: 8)
            StateChip(text: vm.stateWord,
                      tint: vm.inaccessible ? Theme.faint : Theme.tint(vm.powerState),
                      onAccent: selected)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sidebarSelection(selected)
        .contentShape(Capsule())
        // One click selects at once. The double-click that opens the console is a simultaneous
        // gesture, so the first click is not held back while SwiftUI waits for a second one
        // (owner, 3 Oct 2026: selecting felt laggy).
        .onTapGesture {
            model.select(host: host, vm: vm)
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            guard !vm.inaccessible else { return }
            if !selected { model.select(host: host, vm: vm) }
            model.consoleRequest += 1
        })
        // The full name as an in-app label after a short hover (macOS tooltips were unreliable
        // on these rows). Only the name, nothing else.
        .onHover { inside in
            hovering = inside
            if inside {
                Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    if hovering { showName = true }
                }
            } else {
                showName = false
            }
        }
        .overlay(alignment: .topLeading) {
            if showName {
                // Small, and wrapped to the sidebar's width so a long name is never cut.
                Text(vm.name)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Theme.background, in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.line))
                    .frame(maxWidth: max(120, model.sidebarWidth - 48), alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(x: 4, y: -22)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .zIndex(showName ? 10 : 0)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction { model.select(host: host, vm: vm) }
    }
}

/// Reviewing a changed certificate: the two thumbprints, then trust or walk away.
struct TrustSheet: View {
    @Environment(\.dismiss) private var dismiss
    let host: HostModel
    @State private var failure: String?

    var body: some View {
        QuietSheet(title: "The certificate of \(host.address) changed",
                   subtitle: "This can mean the host was reinstalled, or that something is answering in its place.",
                   failure: failure) {
            if case .needsTrust(let expected, let actual) = host.phase {
                VStack(alignment: .leading, spacing: 12) {
                    SheetField("Expected SHA-1") {
                        Text(expected).font(Theme.mono).foregroundStyle(Theme.ink).textSelection(.enabled)
                    }
                    SheetField("Presented now") {
                        Text(actual).font(Theme.mono).foregroundStyle(Theme.attention).textSelection(.enabled)
                    }
                }
            }
        } actions: {
            SheetButtons("Trust the new certificate", action: {
                Task {
                    await host.trustNewCertificate()
                    dismiss()
                }
            })
        }
    }
}
