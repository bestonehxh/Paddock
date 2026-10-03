import PaddockCore
import SwiftUI
import VimClient

enum DetailTab: String, Hashable {
    case overview, snapshots, files, run, shell, console
}

/// The right side: a slim 30 pt bar (sidebar word, VM name, the tabs as plain words, the state
/// words at the right end), then the selected tab's page.
struct DetailView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: DetailTab = .overview

    var body: some View {
        if let host = model.selectedHost, let vm = model.selectedVM {
            VStack(spacing: 0) {
                DetailBar(host: host, vm: vm, tab: $tab)
                Rectangle().fill(Theme.line).frame(height: 1)
                Group {
                    switch tab {
                    case .overview: OverviewView(host: host, vm: vm)
                    case .snapshots: SnapshotsView(host: host, vm: vm)
                    case .files: FilesView(host: host, vm: vm)
                    case .run: RunView(host: host, vm: vm)
                    case .shell: ShellView(host: host, vm: vm)
                    case .console: ConsoleView(host: host, vm: vm)
                    }
                }
                // A new VM gets fresh page state: nothing from the previous VM's Run output,
                // snapshot selection or folder leaks across (review, 3 Oct 2026).
                .id(model.selection)
                .frame(maxHeight: .infinity)
            }
            .onChange(of: model.consoleRequest) { _, _ in tab = .console }
        } else {
            WelcomeView()
        }
    }
}

/// The 30 pt bar. Power is a menu, not a page: Power on, Shut down guest, Reboot guest,
/// Suspend, then Power off and Reset in muted red, then Install VMware Tools….
struct DetailBar: View {
    @Environment(AppModel.self) private var model
    let host: HostModel
    let vm: VMSummary
    @Binding var tab: DetailTab
    @State private var confirming: ConfirmAction?

    enum ConfirmAction: Identifiable {
        case power(VimSession.PowerAction)
        var id: String {
            if case .power(let action) = self { return action.rawValue }
            return ""
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // The one glyph in the app (owner, 3 Oct 2026: "use a symbol for the sidebar").
            Button {
                withAnimation(.easeOut(duration: 0.15)) { model.sidebarVisible.toggle() }
            } label: {
                Image(systemName: model.sidebarVisible ? "sidebar.left" : "sidebar.leading")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(model.sidebarVisible ? "Hide the sidebar (⌘\\)" : "Show the sidebar (⌘\\)")
            .accessibilityLabel(model.sidebarVisible ? "Hide sidebar" : "Show sidebar")

            Text(vm.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .padding(.leading, 18)
                .padding(.trailing, 24)

            tabs

            Spacer(minLength: 12)

            statusChips
        }
        .padding(.leading, model.sidebarVisible || model.windowFullScreen ? 16 : 78)   // clear of the traffic lights
        .padding(.trailing, 16)
        .padding(.top, 6)   // level with the traffic lights now that there is no title bar
        .frame(height: 36)
        .confirmationDialog(
            confirming.map { confirmTitle($0) } ?? "",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible,
            presenting: confirming
        ) { action in
            Button(confirmButton(action), role: confirmRole(action)) {
                if case .power(let power) = action {
                    Task { await host.power(power, vm: vm) }
                }
                confirming = nil
            }
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: { _ in
            Text(confirmMessage)
        }
    }

    /// The tabs as one native segmented control (Look A); Power ▾ and Keys ▾ sit beside it.
    /// The ⌘1…⌘6 shortcuts come from hidden buttons, which a segmented picker can't carry.
    private var tabs: some View {
        HStack(spacing: 12) {
            Picker("Tab", selection: $tab) {
                Text("Overview").tag(DetailTab.overview)
                Text("Snapshots").tag(DetailTab.snapshots)
                Text("Files").tag(DetailTab.files)
                Text("Run").tag(DetailTab.run)
                Text("Shell").tag(DetailTab.shell)
                Text("Console").tag(DetailTab.console)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .labelsHidden()
            .fixedSize()
            .background {
                tabShortcut("1", .overview)
                tabShortcut("2", .snapshots)
                tabShortcut("3", .files)
                tabShortcut("4", .run)
                tabShortcut("5", .shell)
                tabShortcut("6", .console)
            }
            powerMenu
            if tab == .console { keysMenu }
        }
    }

    private func tabShortcut(_ key: KeyEquivalent, _ value: DetailTab) -> some View {
        Button("\(value.rawValue)") { tab = value }
            .keyboardShortcut(key, modifiers: .command)
            .opacity(0)
            .accessibilityHidden(true)
    }

    /// Everything the console used to show in its own rows (owner, 3 Oct 2026): the key
    /// combinations, the clipboard routes, Fit / Actual size, and the stream's state.
    private var keysMenu: some View {
        let status = model.consoleStatus
        return Menu {
            Button("Ctrl-Alt-Del") { model.requestConsole(.ctrlAltDel) }.disabled(!status.connected)
            Button("Paste into console") { model.requestConsole(.pasteIntoConsole) }
            Button("Send to guest clipboard") { model.requestConsole(.sendClipboard) }
            Divider()
            Button("Windows key") { model.requestConsole(.windowsKey) }.disabled(!status.connected)
            Button("Ctrl-Esc") { model.requestConsole(.ctrlEsc) }.disabled(!status.connected)
            Button("Alt-Tab") { model.requestConsole(.altTab) }.disabled(!status.connected)
            Button("Ctrl-Shift-Esc") { model.requestConsole(.ctrlShiftEsc) }.disabled(!status.connected)
            Divider()
            Toggle("Fit to window", isOn: Binding(get: { status.zoomFit }, set: { if $0 { model.requestConsole(.zoomFit) } }))
            Toggle("Actual size", isOn: Binding(get: { !status.zoomFit }, set: { if $0 { model.requestConsole(.zoomActual) } }))
            Toggle("Record for rewind", isOn: Binding(get: { model.consoleRewind }, set: { model.consoleRewind = $0 }))
            Toggle("Share clipboard with the guest", isOn: Binding(get: { model.clipboardSharing }, set: { model.clipboardSharing = $0 }))
                .disabled(!vm.tools.isRunning || !host.hasGuestLogin(vm: vm))
            Toggle("Guest follows window size", isOn: Binding(get: { model.consoleFollowsWindow },
                                                              set: { model.consoleFollowsWindow = $0; if $0 { model.requestConsole(.resizeNow) } }))
                .disabled(!vm.tools.isRunning || !host.hasGuestLogin(vm: vm))
            if vm.tools.isRunning, !host.hasGuestLogin(vm: vm) {
                Text("Save a guest login (Overview) to let the guest follow the window")
            }
            Divider()
            Text([status.size, status.connected ? "\(status.fps) fps" : nil, status.state.isEmpty ? nil : status.state]
                .compactMap { $0 }.joined(separator: " · "))
            if let note = status.note { Text(note) }
            Button("Reconnect") { model.requestConsole(.reconnect) }
            Divider()
            Text("⌘ is Ctrl in the guest · keys go to the guest while the pointer is over it")
        } label: {
            Text("Keys ▾")
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var powerMenu: some View {
        Menu {
            ForEach(VimSession.PowerAction.allCases, id: \.rawValue) { action in
                if action == .powerOff { Divider() }
                Button(role: action.destructive ? .destructive : nil) {
                    if action.destructive {
                        confirming = .power(action)
                    } else {
                        Task { await host.power(action, vm: vm) }
                    }
                } label: {
                    Text(marginNote(for: action) ?? action.title)
                }
                .disabled(disabled(action))
            }
            Divider()
            Button("Install VMware Tools…") {
                Task { await host.mountTools(vm: vm) }
            }
            .disabled(vm.powerState != .poweredOn || vm.inaccessible)
        } label: {
            Text("Power ▾")
                .font(.system(size: 12))
                .foregroundStyle(isReachable && !vm.inaccessible ? Theme.ink : Theme.faint)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!isReachable || vm.inaccessible)
    }

    private var isReachable: Bool {
        if case .connected = host.phase { return true }
        return false
    }

    /// Guest actions need Tools; the reason is written beside the word, per the design.
    private func marginNote(for action: VimSession.PowerAction) -> String? {
        guard action.needsTools, !vm.tools.isRunning else { return nil }
        return "\(action.title) — needs Tools running in the guest"
    }

    private func disabled(_ action: VimSession.PowerAction) -> Bool {
        guard isReachable, !vm.inaccessible, !host.busyVMs.contains(vm.ref.value) else { return true }
        if action.needsTools, !vm.tools.isRunning { return true }
        switch action {
        case .powerOn: return vm.powerState == .poweredOn
        case .shutdownGuest, .rebootGuest: return vm.powerState != .poweredOn
        case .suspend: return vm.powerState != .poweredOn
        case .powerOff, .reset: return vm.powerState == .poweredOff
        }
    }

    /// "Running · Tools running · 10.0.0.5" at the right end: state and Tools as tinted chips
    /// (Look A), the address faint beside them.
    private var statusChips: some View {
        let keyboard = KeyboardLanguage.shared
        return HStack(spacing: 6) {
            // The Mac's input language: the console types on a US layout, so a Thai (or other
            // non-Latin) source means keys won't reach the guest (owner, 3 Oct 2026).
            StateChip(text: "⌨ \(keyboard.tag)", tint: keyboard.isLatin ? Theme.muted : Theme.paused)
                .help(keyboard.isLatin ? "Keyboard input source: \(keyboard.tag)"
                                       : "Keyboard is \(keyboard.tag): switch to English to type into the guest")
            StateChip(text: vm.stateWord,
                      tint: vm.inaccessible ? Theme.faint : Theme.tint(vm.powerState))
            if vm.powerState == .poweredOn, !vm.inaccessible {
                StateChip(text: vm.tools.word, tint: Theme.tint(vm.tools))
            }
            if let ip = vm.ipAddress {
                Text(ip).font(Theme.caption).foregroundStyle(Theme.faint).lineLimit(1)
            }
            if host.busyVMs.contains(vm.ref.value) {
                Text("working…").font(Theme.caption).foregroundStyle(Theme.faint)
            }
        }
        .lineLimit(1)
    }

    // MARK: Confirmation sentences

    private func confirmTitle(_ action: ConfirmAction) -> String {
        if case .power(let power) = action {
            switch power {
            case .powerOff: return "Power off \(vm.name)?"
            case .reset: return "Reset \(vm.name)?"
            default: return power.title
            }
        }
        return ""
    }

    private func confirmButton(_ action: ConfirmAction) -> String {
        if case .power(let power) = action { return power.title }
        return "OK"
    }

    private func confirmRole(_ action: ConfirmAction) -> ButtonRole? {
        .destructive
    }

    private var confirmMessage: String {
        "The guest gets no chance to save anything it is working on."
    }
}

/// The muted-red line under the bar when an action failed on this host.
struct ActionErrorLine: View {
    let text: String?

    var body: some View {
        if let text, !text.isEmpty {
            HStack(spacing: 12) {
                Text(text)
                    .font(Theme.detail)
                    .foregroundStyle(Theme.attention)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .padding(.bottom, 10)
        }
    }
}
