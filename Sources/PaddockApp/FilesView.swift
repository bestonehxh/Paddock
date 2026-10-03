import PaddockCore
import SwiftUI
import VimClient
import UniformTypeIdentifiers

/// The Files tab: a path field with Up / New folder / Refresh, the listing (name, size,
/// modified, Open / Download), and the dashed drop zone that copies files into the guest.
struct FilesView: View {
    @Environment(AppModel.self) private var model
    let host: HostModel
    let vm: VMSummary
    @State private var folder = ""
    @State private var entries: [GuestFileInfo] = []
    @State private var listing = false
    @State private var error: String?
    @State private var transferNote: String?
    /// True once a transfer finished cleanly: the note is then drawn in the soft green.
    @State private var transferDone = false
    @State private var showingNewFolder = false
    @State private var showingLogin = false
    @State private var newFolderName = ""
    @State private var confirmingDelete: GuestFileInfo?
    @State private var dropping = false
    @State private var exportPath: String?
    @State private var exportData: Data?
    /// The host + VM the state on screen belongs to. A listing or transfer captures the key
    /// before it awaits and checks it afterwards, so a slow answer for the VM shown before
    /// never lands in this one's table.
    @State private var liveKey = ""

    /// Host address + moref: morefs repeat across hosts, so `vm.id` alone would collide.
    private var vmKey: String { "\(host.address)/\(vm.ref.value)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                QuietTextField("Folder", text: $folder, prompt: guestHome)
                    .textFieldStyle(.quiet)
                    .onSubmit { list() }
                Button("Up") { goUp() }.buttonStyle(.quietLink).disabled(!canGoUp || listing)
                Button("New folder…") { showingNewFolder = true }.buttonStyle(.quietLink).disabled(listing || !hasLogin)
                Button("Refresh") { list() }.buttonStyle(.quietLink).disabled(listing || !hasLogin)
            }
            .padding(.top, 24)
            .padding(.horizontal, 40)

            if let error {
                Text(error).font(Theme.detail).foregroundStyle(Theme.attention)
                    .padding(.top, 12).padding(.horizontal, 40)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if let transferNote {
                Text(transferNote).font(Theme.detail.monospacedDigit())
                    .foregroundStyle(transferDone ? Theme.on : Theme.muted)
                    .padding(.top, 12).padding(.horizontal, 40)
                    .lineLimit(1).truncationMode(.middle)
            }

            Group {
                if !hasLogin || vm.powerState != .poweredOn || !vm.tools.isRunning {
                    missingLogin
                } else if listing && entries.isEmpty {
                    Text("Listing…").font(Theme.detail).foregroundStyle(Theme.faint).padding(.top, 20)
                } else {
                    table
                }
            }
            .padding(.top, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            dropZone
                .padding(.horizontal, 40)
                .padding(.bottom, 20)
        }
        .background(Theme.background)
        .onAppear {
            liveKey = vmKey
            if folder.isEmpty { folder = guestHome; list() }
        }
        .onChange(of: vmKey) { _, _ in
            liveKey = vmKey
            folder = guestHome
            entries = []
            error = nil
            transferNote = nil
            transferDone = false
            listing = false
            list()
        }
        .sheet(isPresented: $showingNewFolder) { newFolderSheet }
        .sheet(isPresented: $showingLogin) { GuestLoginSheet(host: host, vm: vm) }
        .onChange(of: hasLogin) { _, has in
            // The login was just saved from this tab: list straight away.
            if has, entries.isEmpty, !listing { list() }
        }
        .confirmationDialog(
            "Delete \(confirmingDelete.map { name(of: $0.path) } ?? "")?",
            isPresented: Binding(get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }),
            titleVisibility: .visible,
            presenting: confirmingDelete
        ) { item in
            Button("Delete", role: .destructive) {
                Task { await delete(item) }
                confirmingDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmingDelete = nil }
        } message: { item in
            Text(item.kind == .directory
                 ? "The folder and everything in it goes away. This cannot be undone."
                 : "The file goes away in the guest. This cannot be undone.")
        }
        .overlay {
            if dropping {
                Rectangle().fill(Theme.background.opacity(0.8))
                    .overlay(alignment: .center) {
                        Text("Drop to copy into \(folder)")
                            .font(Theme.emphasis).foregroundStyle(Theme.ink)
                            .padding(.horizontal, 28)
                            .padding(.vertical, 18)
                            .overlay(Rectangle().stroke(Theme.ink, lineWidth: 1).padding(-10))
                    }
            }
        }
    }

    // MARK: Pieces

    private var hasLogin: Bool { host.hasGuestLogin(vm: vm) }

    private var guestHome: String {
        if let user = host.guestUser(vm: vm) {
            return VimSession.homeFolder(for: vm.guestFamily, login: GuestLogin(username: user, password: ""))
        }
        return vm.guestFamily == .windows ? "C:\\" : "/"
    }

    private var canGoUp: Bool {
        VimSession.parent(of: folder, family: vm.guestFamily) != nil
    }

    /// What stands between the user and the listing: the VM's power, Tools, or the saved login.
    @ViewBuilder private var missingLogin: some View {
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
                Text("Files are read and written as that user; the password goes into the Keychain.")
                    .font(Theme.caption).foregroundStyle(Theme.faint)
            }
        }
        .padding(.top, 20)
        .padding(.horizontal, 40)
    }

    private var table: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if entries.isEmpty {
                    QuietNote("The folder is empty.").padding(.vertical, 12)
                }
                ForEach(entries) { entry in
                    QuietRow {
                        row(entry)
                    }
                }
            }
            .padding(.horizontal, 40)
        }
    }

    private func row(_ entry: GuestFileInfo) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(entry.name)
                .font(Theme.detail.weight(entry.kind == .directory ? .medium : .regular))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            Text(size(entry)).font(Theme.caption).foregroundStyle(Theme.faint)
                .frame(width: 90, alignment: .trailing)
            Text(entry.modified.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "")
                .font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.faint)
                .frame(width: 160, alignment: .trailing)
            Group {
                if entry.kind == .directory {
                    Button("Open") { enter(entry) }
                        .buttonStyle(.quietLink).font(Theme.caption)
                } else if entry.kind == .file {
                    Button("Download") { download(entry) }
                        .buttonStyle(.quietLink).font(Theme.caption)
                } else {
                    Text(" ")
                }
            }
            .frame(width: 70, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .contextMenu {
            if entry.kind == .directory {
                Button("Open") { enter(entry) }
            }
            Button("Delete…", role: .destructive) { confirmingDelete = entry }
        }
        .onTapGesture { if entry.kind == .directory { enter(entry) } }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Name").font(Theme.caption).foregroundStyle(Theme.faint)
            Spacer(minLength: 12)
            Text("Size").font(Theme.caption).foregroundStyle(Theme.faint).frame(width: 90, alignment: .trailing)
            Text("Modified").font(Theme.caption).foregroundStyle(Theme.faint).frame(width: 160, alignment: .trailing)
            Text(" ").frame(width: 70)
        }
        .padding(.bottom, 6)
    }

    /// The dashed zone under the table; files dropped here (or chosen through the link) are
    /// copied into the guest folder.
    private var dropZone: some View {
        HStack(spacing: 4) {
            Text("Drop files here to copy them into \(folder)")
                .lineLimit(1)
                .truncationMode(.middle)
            Button("or click to choose") { choose() }
                .buttonStyle(.quietLink)
                .disabled(!hasLogin || vm.powerState != .poweredOn || !vm.tools.isRunning)
        }
        .font(Theme.caption)
        .foregroundStyle(Theme.faint)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .overlay(
            Rectangle().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
                .foregroundStyle(dropping ? Theme.ink : Theme.control)
        )
        .dropDestination(for: URL.self) { urls, _ in
            upload(urls.filter { $0.isFileURL })
        } isTargeted: { dropping = $0 }
    }

    // MARK: Actions

    private func list() {
        guard hasLogin, let login = host.guestLogin(vm: vm) else { return }
        listing = true
        error = nil
        let target = folder
        let key = vmKey
        Task {
            do {
                let session = try host.sessionForGuest()
                let files = try await session.listFiles(vm: vm.ref, login: login, path: target)
                // The user may have moved to another VM while the host answered.
                guard key == liveKey else { return }
                entries = files.sorted { a, b in
                    if (a.kind == .directory) != (b.kind == .directory) { return a.kind == .directory }
                    return a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
                folder = target
            } catch {
                guard key == liveKey else { return }
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            listing = false
        }
    }

    private func enter(_ entry: GuestFileInfo) {
        folder = VimSession.join(folder, entry.name, family: vm.guestFamily)
        list()
    }

    private func goUp() {
        guard let up = VimSession.parent(of: folder, family: vm.guestFamily) else { return }
        folder = up
        list()
    }

    private func delete(_ entry: GuestFileInfo) async {
        guard let login = host.guestLogin(vm: vm) else { return }
        let key = vmKey
        do {
            let session = try host.sessionForGuest()
            if entry.kind == .directory {
                try await session.deleteDirectory(vm: vm.ref, login: login, path: entry.path)
            } else {
                try await session.deleteFile(vm: vm.ref, login: login, path: entry.path)
            }
            guard key == liveKey else { return }
            list()
        } catch {
            guard key == liveKey else { return }
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// The open panel behind "or click to choose": any number of files, uploaded like a drop.
    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Copy"
        panel.message = "Copy into \(folder)"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        _ = upload(panel.urls)
    }

    /// Copies local files into the current guest folder, streaming from disk, with the bytes
    /// so far in the note while each one goes up.
    private func upload(_ urls: [URL]) -> Bool {
        guard let login = host.guestLogin(vm: vm), !urls.isEmpty else { return false }
        // Captured now: the user may change the folder (or the VM) while the files go up.
        let destination = folder
        let family = vm.guestFamily
        let ref = vm.ref
        let key = vmKey
        let count = urls.count
        transferDone = false
        transferNote = "Uploading \(urls[0].lastPathComponent)…"
        Task {
            do {
                let session = try host.sessionForGuest()
                for (index, url) in urls.enumerated() {
                    let name = url.lastPathComponent
                    let position = count > 1 ? " (\(index + 1) of \(count))" : ""
                    let target = VimSession.join(destination, name, family: family)
                    try await session.upload(file: url, to: target, vm: ref, login: login, family: family) { sent, total in
                        Task { @MainActor in
                            guard key == liveKey else { return }
                            transferNote = "Uploading \(name)\(position) · \(bytes(sent)) of \(bytes(total))"
                        }
                    }
                }
                guard key == liveKey else { return }
                transferNote = count == 1 ? "\(urls[0].lastPathComponent) · done" : "\(count) files · done"
                transferDone = true
                if destination == folder { list() }
            } catch {
                guard key == liveKey else { return }
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                transferNote = nil
            }
        }
        return true
    }

    /// Pulls the file's bytes, then opens the save panel with them.
    private func download(_ entry: GuestFileInfo) {
        guard let login = host.guestLogin(vm: vm) else { return }
        transferDone = false
        transferNote = "Downloading \(name(of: entry.path))…"
        let key = vmKey
        Task {
            do {
                let session = try host.sessionForGuest()
                let data = try await session.download(entry.path, vm: vm.ref, login: login)
                guard key == liveKey else { return }
                exportData = data
                exportPath = name(of: entry.path)
                transferNote = nil
                savePanel()
            } catch {
                guard key == liveKey else { return }
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                transferNote = nil
            }
        }
    }

    /// The NSSavePanel run by hand, so the bytes downloaded above go wherever the user picks.
    private func savePanel() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = exportPath ?? "file"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else {
            exportData = nil
            exportPath = nil
            return
        }
        do {
            try exportData?.write(to: url, options: .atomic)
            transferNote = "Saved \(url.lastPathComponent) · done"
            transferDone = true
        } catch {
            self.error = error.localizedDescription
        }
        exportData = nil
        exportPath = nil
    }

    private var newFolderSheet: some View {
        QuietSheet(title: "New folder in \(folder)", failure: error) {
            SheetField("Name") {
                QuietTextField("Name", text: $newFolderName, prompt: "new folder")
            }
        } actions: {
            SheetButtons("Create", disabled: newFolderName.trimmingCharacters(in: .whitespaces).isEmpty, action: {
                guard let login = host.guestLogin(vm: vm) else { return }
                let path = VimSession.join(folder, newFolderName.trimmingCharacters(in: .whitespaces), family: vm.guestFamily)
                let key = vmKey
                Task {
                    do {
                        let session = try host.sessionForGuest()
                        try await session.makeDirectory(vm: vm.ref, login: login, path: path)
                        showingNewFolder = false
                        newFolderName = ""
                        guard key == liveKey else { return }
                        list()
                    } catch {
                        showingNewFolder = false
                        guard key == liveKey else { return }
                        self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    }
                }
            })
        }
    }

    private func name(of path: String) -> String {
        GuestFileInfo(path: path, kind: .file, size: 0, modified: nil).name
    }

    private func size(_ entry: GuestFileInfo) -> String {
        switch entry.kind {
        case .directory: return "—"
        default: return bytes(entry.size)
        }
    }

    /// "12 MB", "800 MB", "1.2 GB": the same rounding as the Size column.
    private func bytes(_ n: Int64) -> String {
        let bytes = Double(n)
        if bytes >= 1_000_000_000 { return String(format: "%.1f GB", bytes / 1_000_000_000) }
        if bytes >= 1_000_000 { return String(format: "%.1f MB", bytes / 1_000_000) }
        if bytes >= 1_000 { return String(format: "%.0f kB", bytes / 1_000) }
        return "\(n) B"
    }
}
