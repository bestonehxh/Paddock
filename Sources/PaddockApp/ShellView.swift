import AppKit
import PaddockCore
import SwiftUI
import VimClient

/// A persistent shell in the guest over VMware Tools (no guest network needed): one `bash`
/// (or PowerShell) stays alive between commands, its output streams into the pane. Round trip
/// is about a second; full-screen programs don't work (stdin isn't a terminal).
struct ShellView: View {
    @Environment(AppModel.self) private var model
    let host: HostModel
    let vm: VMSummary

    @State private var shell: GuestShell?
    @State private var output = ""
    @State private var command = ""
    @State private var history: [String] = []
    @State private var historyIndex: Int?
    @State private var draft = ""
    @State private var status = ""
    @State private var error: String?
    @State private var busy = false
    @State private var lastRoundTrip: TimeInterval?
    @State private var pollTask: Task<Void, Never>?
    @State private var showingLogin = false
    @FocusState private var fieldFocused: Bool

    private var hasLogin: Bool { host.hasGuestLogin(vm: vm) }
    private var canUse: Bool { vm.canUseGuest && hasLogin }
    private var shellWord: String { vm.guestFamily == .windows ? "PowerShell" : (vm.guestFamily == .darwin ? "zsh" : "bash") }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !vm.canUseGuest {
                gate(vm.powerState != .poweredOn ? "The VM is off; the shell needs it running with VMware Tools."
                                                 : "VMware Tools isn't running in the guest, so there is no way in without a network.")
            } else if !hasLogin {
                gate("A guest login is needed to open a shell through Tools.", loginButton: true)
            } else {
                outputPane
                Rectangle().fill(Theme.line).frame(height: 1)
                inputRow
            }
        }
        .background(Theme.background)
        .task(id: "\(host.address)/\(vm.ref.value)/\(hasLogin)") {
            if canUse { await open() }
        }
        .onDisappear { Task { await close() } }
        .sheet(isPresented: $showingLogin) { GuestLoginSheet(host: host, vm: vm) }
    }

    // MARK: Pieces

    private func gate(_ sentence: String, loginButton: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(sentence).font(Theme.detail).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if loginButton {
                Button("Set guest login…") { showingLogin = true }
                    .buttonStyle(.quietLink).font(Theme.detail)
            }
        }
        .padding(EdgeInsets(top: 28, leading: 40, bottom: 24, trailing: 40))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var outputPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(output.isEmpty ? (status.isEmpty ? "Opening \(shellWord) in \(vm.name)…" : status) : output)
                        .font(Theme.mono)
                        .foregroundStyle(output.isEmpty ? Theme.faint : Theme.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if let error {
                        Text(error).font(Theme.detail).foregroundStyle(Theme.attention).padding(.top, 8)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(EdgeInsets(top: 14, leading: 40, bottom: 10, trailing: 40))
            }
            .onChange(of: output) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var inputRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(vm.guestFamily == .windows ? "PS>" : "$")
                .font(Theme.mono).foregroundStyle(Theme.faint)
            TextField("Command", text: $command, prompt: Text(verbatim: ""))
                .textFieldStyle(.quietMonospaced)
                .focused($fieldFocused)
                .onSubmit { submit() }
                .onKeyPress(.upArrow) { recall(-1); return .handled }
                .onKeyPress(.downArrow) { recall(1); return .handled }
                .disabled(shell == nil || busy)
            Button("Send") { submit() }
                .buttonStyle(.quietLink).font(Theme.detail)
                .disabled(shell == nil || busy || command.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Restart") { Task { await close(); await open() } }
                .buttonStyle(.quietLink).font(Theme.detail)
            Button("Clear") { output = "" }
                .buttonStyle(.quietLink).font(Theme.detail)
            Spacer(minLength: 8)
            Text(statusLine).font(Theme.caption).foregroundStyle(Theme.faint).lineLimit(1)
        }
        .padding(EdgeInsets(top: 8, leading: 40, bottom: 10, trailing: 40))
    }

    private var statusLine: String {
        var parts = ["\(shellWord) as \(host.guestUser(vm: vm) ?? "?")"]
        if let rt = lastRoundTrip { parts.append(String(format: "%.1f s round trip", rt)) }
        if !status.isEmpty { parts.append(status) }
        return parts.joined(separator: " · ")
    }

    // MARK: Session

    private func open() async {
        guard shell == nil, let login = host.guestLogin(vm: vm) else { return }
        error = nil
        status = "starting…"
        do {
            let s = try host.sessionForGuest()
            let sh = GuestShell(session: s, vm: vm.ref, login: login, family: vm.guestFamily)
            try await sh.start()
            shell = sh
            status = "running"
            fieldFocused = true
            pollTask = Task { await pollLoop(sh) }
        } catch {
            status = ""
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func close() async {
        pollTask?.cancel()
        pollTask = nil
        if let shell { await shell.stop() }
        shell = nil
        status = ""
    }

    /// Downloads new output every 600 ms, faster right after a command.
    private func pollLoop(_ sh: GuestShell) async {
        var quiet = 0
        while !Task.isCancelled {
            do {
                let chunk = try await sh.poll()
                if !chunk.isEmpty {
                    append(chunk)
                    quiet = 0
                } else {
                    quiet += 1
                }
                if await sh.ended {
                    status = "the shell exited"
                    busy = false
                    return
                }
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            try? await Task.sleep(for: .milliseconds(quiet > 5 ? 1200 : 500))
        }
    }

    private func append(_ chunk: String) {
        // bash -i on a pipe always says this once; it isn't news.
        let cleaned = chunk.replacingOccurrences(of: "bash: no job control in this shell\n", with: "")
        output += cleaned
        if output.count > 400_000 { output = String(output.suffix(300_000)) }
        if busy, let sentAt { lastRoundTrip = Date().timeIntervalSince(sentAt); self.sentAt = nil }
        busy = false
    }

    @State private var sentAt: Date?

    private func submit() {
        let text = command
        guard let shell, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        command = ""
        historyIndex = nil
        history.removeAll { $0 == text }
        history.append(text)
        if history.count > 100 { history.removeFirst() }
        busy = true
        sentAt = Date()
        error = nil
        Task {
            do {
                try await shell.send(text)
            } catch {
                busy = false
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func recall(_ step: Int) {
        guard !history.isEmpty else { return }
        if historyIndex == nil { draft = command }
        var index = (historyIndex ?? history.count) + step
        index = max(0, min(history.count, index))
        historyIndex = index == history.count ? nil : index
        command = index == history.count ? draft : history[index]
    }
}
