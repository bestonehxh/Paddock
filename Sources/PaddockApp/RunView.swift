import PaddockCore
import SwiftUI
import VimClient

/// The Run tab: a command field (or a script file), the note saying who it runs as, a
/// monospace output pane with "exit 0 · 1.8 s", and Copy / Save / Clear under it.
struct RunView: View {
    @Environment(AppModel.self) private var model
    let host: HostModel
    let vm: VMSummary
    @State private var command = ""
    @State private var workingDirectory = ""
    @State private var running = false
    @State private var error: String?
    @State private var result: VimSession.RunResult?
    @State private var pasteNote: String?
    @State private var showingLogin = false
    /// Commands already run, newest last, per VM (keyed by host address + moref so the same
    /// moref on two hosts stays apart); the last 50 are kept.
    @State private var histories: [String: [String]] = [:]
    /// Where ↑/↓ stand in the history; nil while typing a fresh command.
    @State private var historyIndex: Int?
    /// What was in the field before ↑ started replacing it, so ↓ past the end brings it back.
    @State private var draft = ""
    /// Bumped when the VM shown changes: a run started for the VM before is then ignored.
    @State private var generation = 0

    private static let historyLimit = 50

    private var shell: VimSession.Shell { VimSession.Shell.default(for: vm.guestFamily) }
    private var vmKey: String { "\(host.address)/\(vm.ref.value)" }
    private var history: [String] { histories[vmKey] ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                input
                    .padding(.top, 24)
                if let error {
                    Text(error).font(Theme.detail).foregroundStyle(Theme.attention)
                        .padding(.top, 12)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                output
                    .padding(.top, 20)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 24)
            .frame(maxWidth: 1200, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: vmKey) { _, _ in
            // Another VM: the field, the output and any note belonged to the one before.
            generation += 1
            command = ""
            workingDirectory = ""
            result = nil
            error = nil
            pasteNote = nil
            running = false
            historyIndex = nil
            draft = ""
        }
        .sheet(isPresented: $showingLogin) { GuestLoginSheet(host: host, vm: vm) }
    }

    private var hasLogin: Bool { host.hasGuestLogin(vm: vm) }

    @ViewBuilder private var input: some View {
        if !hasLogin || vm.powerState != .poweredOn || !vm.tools.isRunning {
            VStack(alignment: .leading, spacing: 8) {
                if vm.powerState != .poweredOn {
                    Text("The VM is off.")
                        .font(Theme.detail).foregroundStyle(Theme.muted)
                } else if !vm.tools.isRunning {
                    Text("VMware Tools isn't running in the guest.")
                        .font(Theme.detail).foregroundStyle(Theme.muted)
                    ToolsInstallHint(host: host, vm: vm)
                } else {
                    Text("No guest login saved for this VM.")
                        .font(Theme.detail).foregroundStyle(Theme.muted)
                    Button("Set guest login…") { showingLogin = true }
                        .buttonStyle(.quietLink)
                    Text("Commands run as that user; the password goes into the Keychain.")
                        .font(Theme.caption).foregroundStyle(Theme.faint)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                QuietTextField("Command", text: $command, prompt: example, axis: .vertical)
                    .textFieldStyle(.quietMonospaced)
                    .onSubmit { run() }
                    .onKeyPress(.upArrow) { recall(step: -1) }
                    .onKeyPress(.downArrow) { recall(step: 1) }
                    .onChange(of: command) { _, new in
                        // Typing (not ↑/↓ replacing the text) leaves the history walk.
                        if let i = historyIndex, history.indices.contains(i), history[i] != new {
                            historyIndex = nil
                        }
                    }
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Button("Run") { run() }
                        .buttonStyle(.quietLink)
                        .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || running)
                    Button("Script file…") { pickScript() }
                        .buttonStyle(.quietLink)
                        .disabled(running)
                    Button("Send to guest clipboard") { pasteClipboard() }
                        .buttonStyle(.quietLink)
                        .disabled(running)
                    if running {
                        Text("Running…").font(Theme.detail).foregroundStyle(Theme.faint)
                    }
                }
                Text(note)
                    .font(Theme.caption).foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
                QuietTextField("Working folder", text: $workingDirectory, prompt: defaultWorkingFolder)
                    .textFieldStyle(.quiet)
            }
        }
    }

    private var note: String {
        let user = host.guestUser(vm: vm) ?? "the saved user"
        var s = "Runs as \(user) in \(shell.title)"
        if !workingDirectory.isEmpty { s += " · working folder \(workingDirectory)" }
        if !history.isEmpty { s += " · ↑ recalls earlier commands" }
        return s
    }

    private var example: String {
        switch vm.guestFamily {
        case .windows: "Get-Process | Select-Object -First 5"
        case .darwin: "sw_vers"
        default: "uname -a"
        }
    }

    private var defaultWorkingFolder: String {
        vm.guestFamily == .windows ? "C:\\" : "/tmp"
    }

    private var output: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let result {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text(footer(result))
                        .font(Theme.caption.monospacedDigit())
                        .foregroundStyle(footerTint(result))
                    Spacer(minLength: 12)
                    Button("Copy output") { copyOutput(result) }.buttonStyle(.quietLink).font(Theme.caption)
                    Button("Copy output to guest") { pasteOutputToGuest(result) }
                        .buttonStyle(.quietLink).font(Theme.caption)
                        .disabled(running || result.output.isEmpty || !hasLogin)
                    Button("Save output…") { saveOutput(result) }.buttonStyle(.quietLink).font(Theme.caption)
                    Button("Clear") { self.result = nil; pasteNote = nil }.buttonStyle(.quietLink).font(Theme.caption)
                }
                if let pasteNote {
                    Text(pasteNote).font(Theme.caption).foregroundStyle(Theme.faint)
                }
                ScrollView(.horizontal) {
                    Text(result.output.isEmpty ? "(no output)" : result.output)
                        .font(Theme.mono)
                        .foregroundStyle(Theme.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(14)
                .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
                .background(Theme.inset)
            } else {
                if let pasteNote {
                    Text(pasteNote).font(Theme.caption).foregroundStyle(Theme.faint)
                }
                QuietNote("Output lands here. Everything the command prints, and how it ended.")
            }
        }
    }

    private func footer(_ result: VimSession.RunResult) -> String {
        var s = result.exitCode.map { "exit \($0)" } ?? "finished"
        s += String(format: " · %.1f s", result.duration)
        return s
    }

    /// Green for a clean exit, the soft red for anything else; muted when the exit code is unknown.
    private func footerTint(_ result: VimSession.RunResult) -> Color {
        switch result.exitCode {
        case nil: Theme.muted
        case 0: Theme.on
        default: Theme.off
        }
    }

    // MARK: History

    /// ↑ walks back through earlier commands, ↓ forward and finally back to what was being typed.
    /// Only for a single-line field: in a multi-line script the arrows move between lines.
    private func recall(step: Int) -> KeyPress.Result {
        let items = history
        guard !items.isEmpty, !command.contains("\n") else { return .ignored }
        let next: Int?
        if let i = historyIndex {
            let candidate = i + step
            next = items.indices.contains(candidate) ? candidate : (candidate >= items.count ? nil : i)
        } else {
            guard step < 0 else { return .ignored }
            draft = command
            next = items.count - 1
        }
        if let next {
            historyIndex = next
            command = items[next]
        } else {
            historyIndex = nil
            command = draft
        }
        return .handled
    }

    private func remember(_ script: String) {
        var items = history.filter { $0 != script }
        items.append(script)
        if items.count > Self.historyLimit { items.removeFirst(items.count - Self.historyLimit) }
        histories[vmKey] = items
        historyIndex = nil
        draft = ""
    }

    // MARK: Actions

    private func run() {
        guard let login = host.guestLogin(vm: vm) else { return }
        let script = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !script.isEmpty else { return }
        remember(script)
        running = true
        error = nil
        let started = generation
        Task {
            do {
                let session = try host.sessionForGuest()
                let r = try await session.run(script, shell: shell, vm: vm.ref, login: login, family: vm.guestFamily,
                                              workingDirectory: workingDirectory.isEmpty ? nil : workingDirectory)
                guard started == generation else { return }
                result = r
            } catch {
                guard started == generation else { return }
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            running = false
        }
    }

    private func pickScript() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            command = try String(contentsOf: url, encoding: .utf8)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// "Paste to guest": the Mac clipboard goes to the guest's clipboard through Tools, the same
    /// as on the Console tab (needs the user's desktop session in the guest).
    private func pasteClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            pasteNote = "The Mac's clipboard holds no text."
            return
        }
        sendToGuestClipboard(text, what: "The Mac's clipboard")
    }

    /// "Copy output to guest": the output pane's text goes to the guest's clipboard.
    private func pasteOutputToGuest(_ result: VimSession.RunResult) {
        guard !result.output.isEmpty else { return }
        sendToGuestClipboard(result.output, what: "The output")
    }

    private func sendToGuestClipboard(_ text: String, what: String) {
        guard let login = host.guestLogin(vm: vm) else { return }
        pasteNote = "Copying to the guest's clipboard…"
        let started = generation
        Task {
            do {
                let session = try host.sessionForGuest()
                try await session.paste(text, vm: vm.ref, login: login, family: vm.guestFamily)
                guard started == generation else { return }
                pasteNote = "\(what) is on the guest's clipboard: \(text.count) characters."
            } catch {
                guard started == generation else { return }
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                pasteNote = nil
            }
        }
    }

    private func copyOutput(_ result: VimSession.RunResult) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result.output, forType: .string)
        pasteNote = "Copied to the Mac's clipboard."
    }

    private func saveOutput(_ result: VimSession.RunResult) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "output.txt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try result.output.write(to: url, atomically: true, encoding: .utf8)
            pasteNote = "Saved \(url.lastPathComponent)."
        } catch {
            self.error = error.localizedDescription
        }
    }
}
