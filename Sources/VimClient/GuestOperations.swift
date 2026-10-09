import Foundation

/// Guest operations through VMware Tools: files, directories, programs, and the helpers the app
/// builds on them (run with output, paste to clipboard).
extension VimSession {
    private func auth(_ login: GuestLogin) -> XMLOut.Element {
        .typed("auth", "NamePasswordAuthentication", [
            .bool("interactiveSession", login.interactive),
            .text("username", login.username), .text("password", login.password),
        ])
    }

    private func fileManager() async throws -> MoRef {
        guard let fm = try await requireContent().fileManager else { throw VimError.guestOperation("Guest operations aren't available on this host") }
        return fm
    }

    private func guestProcessManagerRef() async throws -> MoRef {
        _ = try await requireContent()
        guard let pm = self.processManager else { throw VimError.guestOperation("Guest operations aren't available on this host") }
        return pm
    }

    /// Rewrites the `https://*/guestFile?…` URL the host returns to the host's address.
    private func transferURL(_ s: String) throws -> URL {
        var fixed = s
        if let r = fixed.range(of: "://*") { fixed.replaceSubrange(r, with: "://\(host)") }
        else if let r = fixed.range(of: "://*:") { fixed.replaceSubrange(r, with: "://\(host):") }
        guard let url = URL(string: fixed) else { throw VimError.malformedResponse("transfer URL") }
        return url
    }

    // MARK: Files

    public func listFiles(vm: MoRef, login: GuestLogin, path: String, pattern: String? = nil) async throws -> [GuestFileInfo] {
        let fm = try await fileManager()
        var out: [GuestFileInfo] = []
        var index = 0
        while true {
            var args: [XMLOut.Element] = [.ref("vm", vm), auth(login), .text("filePath", path), .int("index", index), .int("maxResults", 500)]
            if let pattern { args.append(.text("matchPattern", pattern)) }
            let r = try await call("ListFilesInGuest", this: fm, args)
            guard let rv = r["returnval"] else { break }
            let files = rv.all("files")
            for f in files {
                guard let p = f.string("path") else { continue }
                let kind = GuestFileInfo.Kind(rawValue: f.string("type") ?? "file") ?? .file
                out.append(GuestFileInfo(path: p, kind: kind, size: f.int64("size") ?? 0, modified: f["attributes"]?.date("modificationTime")))
            }
            index += files.count
            if (rv.int("remaining") ?? 0) == 0 || files.isEmpty { break }
        }
        return out.filter { $0.name != "." && $0.name != ".." }
    }

    public func makeDirectory(vm: MoRef, login: GuestLogin, path: String) async throws {
        try await call("MakeDirectoryInGuest", this: await fileManager(), [.ref("vm", vm), auth(login), .text("directoryPath", path), .bool("createParentDirectories", true)])
    }

    public func deleteFile(vm: MoRef, login: GuestLogin, path: String) async throws {
        try await call("DeleteFileInGuest", this: await fileManager(), [.ref("vm", vm), auth(login), .text("filePath", path)])
    }

    public func deleteDirectory(vm: MoRef, login: GuestLogin, path: String) async throws {
        try await call("DeleteDirectoryInGuest", this: await fileManager(), [.ref("vm", vm), auth(login), .text("directoryPath", path), .bool("recursive", true)])
    }

    public func createTemporaryFile(vm: MoRef, login: GuestLogin, prefix: String, suffix: String, directory: String? = nil) async throws -> String {
        var args: [XMLOut.Element] = [.ref("vm", vm), auth(login), .text("prefix", prefix), .text("suffix", suffix)]
        if let directory { args.append(.text("directoryPath", directory)) }
        let r = try await call("CreateTemporaryFileInGuest", this: await fileManager(), args)
        guard let p = r.string("returnval") else { throw VimError.malformedResponse("temp file") }
        return p
    }

    public func createTemporaryDirectory(vm: MoRef, login: GuestLogin, prefix: String) async throws -> String {
        let r = try await call("CreateTemporaryDirectoryInGuest", this: await fileManager(), [.ref("vm", vm), auth(login), .text("prefix", prefix), .text("suffix", "")])
        guard let p = r.string("returnval") else { throw VimError.malformedResponse("temp dir") }
        return p
    }

    /// Uploads bytes to a path in the guest.
    public func upload(_ data: Data, to guestPath: String, vm: MoRef, login: GuestLogin, family: GuestFamily, overwrite: Bool = true,
                       executable: Bool = false) async throws {
        let attrs: XMLOut.Element = family == .windows
            ? .typed("fileAttributes", "GuestWindowsFileAttributes", [])
            : .typed("fileAttributes", "GuestPosixFileAttributes", [.int64("permissions", executable ? 0o755 : 0o644)])
        let r = try await call("InitiateFileTransferToGuest", this: await fileManager(), [
            .ref("vm", vm), auth(login), .text("guestFilePath", guestPath), attrs, .int64("fileSize", Int64(data.count)), .bool("overwrite", overwrite),
        ])
        guard let urlString = r.string("returnval") else { throw VimError.malformedResponse("upload URL") }
        var request = URLRequest(url: try transferURL(urlString))
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await transport.urlSession.upload(for: request, from: data)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw VimError.guestOperation("Upload failed (HTTP \(status))") }
    }

    /// Uploads a local file, streaming from disk.
    public func upload(file: URL, to guestPath: String, vm: MoRef, login: GuestLogin, family: GuestFamily, overwrite: Bool = true,
                       progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard let size = attributes[.size] as? Int64, size >= 0 else {
            throw VimError.guestOperation("Couldn't read the size of \(file.lastPathComponent)")
        }
        let attrs: XMLOut.Element = family == .windows
            ? .typed("fileAttributes", "GuestWindowsFileAttributes", [])
            : .typed("fileAttributes", "GuestPosixFileAttributes", [.int64("permissions", 0o644)])
        let r = try await call("InitiateFileTransferToGuest", this: await fileManager(), [
            .ref("vm", vm), auth(login), .text("guestFilePath", guestPath), attrs, .int64("fileSize", size), .bool("overwrite", overwrite),
        ])
        guard let urlString = r.string("returnval") else { throw VimError.malformedResponse("upload URL") }
        var request = URLRequest(url: try transferURL(urlString))
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let task = TransferProgress(total: size, progress: progress)
        let (_, response) = try await transport.urlSession.upload(for: request, fromFile: file, delegate: task)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw VimError.guestOperation("Upload failed (HTTP \(status))") }
    }

    /// Downloads a guest file's bytes.
    public func download(_ guestPath: String, vm: MoRef, login: GuestLogin) async throws -> Data {
        let r = try await call("InitiateFileTransferFromGuest", this: await fileManager(), [.ref("vm", vm), auth(login), .text("guestFilePath", guestPath)])
        guard let urlString = r["returnval"]?.string("url") else { throw VimError.malformedResponse("download URL") }
        let (data, response) = try await transport.urlSession.data(from: try transferURL(urlString))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw VimError.guestOperation("Download failed (HTTP \(status))") }
        return data
    }

    /// Downloads a guest file's bytes from `offset` on. The host may ignore the Range header
    /// and answer with the whole file — `partial` says which happened, so callers diff the
    /// front themselves in that case. 416 (offset past the end) comes back as an empty whole
    /// file: the caller resets its offset and starts over.
    public func download(_ guestPath: String, from offset: Int64, vm: MoRef, login: GuestLogin) async throws -> (data: Data, partial: Bool) {
        let r = try await call("InitiateFileTransferFromGuest", this: await fileManager(), [.ref("vm", vm), auth(login), .text("guestFilePath", guestPath)])
        guard let urlString = r["returnval"]?.string("url") else { throw VimError.malformedResponse("download URL") }
        var request = URLRequest(url: try transferURL(urlString))
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let (data, response) = try await transport.urlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 416 { return (data: Data(), partial: false) }
        guard (200..<300).contains(status) else { throw VimError.guestOperation("Download failed (HTTP \(status))") }
        return (data, status == 206)
    }

    /// Downloads a guest file to a local path.
    public func download(_ guestPath: String, to local: URL, vm: MoRef, login: GuestLogin,
                         progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws {
        let r = try await call("InitiateFileTransferFromGuest", this: await fileManager(), [.ref("vm", vm), auth(login), .text("guestFilePath", guestPath)])
        guard let rv = r["returnval"], let urlString = rv.string("url") else { throw VimError.malformedResponse("download URL") }
        let task = TransferProgress(total: rv.int64("size") ?? 0, progress: progress)
        let (tmp, response) = try await transport.urlSession.download(from: try transferURL(urlString), delegate: task)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw VimError.guestOperation("Download failed (HTTP \(status))") }
        try? FileManager.default.removeItem(at: local)
        try FileManager.default.moveItem(at: tmp, to: local)
    }

    final class TransferProgress: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
        let total: Int64
        let progress: (@Sendable (Int64, Int64) -> Void)?
        init(total: Int64, progress: (@Sendable (Int64, Int64) -> Void)?) {
            self.total = total
            self.progress = progress
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
            progress?(totalBytesSent, totalBytesExpectedToSend > 0 ? totalBytesExpectedToSend : total)
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            progress?(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : total)
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    }

    // MARK: Programs

    public func startProgram(vm: MoRef, login: GuestLogin, program: String, arguments: String, workingDirectory: String? = nil,
                             environment: [String] = []) async throws -> Int64 {
        var spec: [XMLOut.Element] = [.text("programPath", program), .text("arguments", arguments)]
        if let workingDirectory { spec.append(.text("workingDirectory", workingDirectory)) }
        spec += environment.map { .text("envVariables", $0) }
        let r = try await call("StartProgramInGuest", this: await guestProcessManagerRef(), [.ref("vm", vm), auth(login), .typed("spec", "GuestProgramSpec", spec)])
        guard let pid = r.int64("returnval") else { throw VimError.malformedResponse("pid") }
        return pid
    }

    public func listProcesses(vm: MoRef, login: GuestLogin, pids: [Int64] = []) async throws -> [GuestProcessInfo] {
        let r = try await call("ListProcessesInGuest", this: await guestProcessManagerRef(), [.ref("vm", vm), auth(login)] + pids.map { .int64("pids", $0) })
        return r.all("returnval").compactMap { p in
            guard let pid = p.int64("pid") else { return nil }
            return GuestProcessInfo(pid: pid, name: p.string("name") ?? "", owner: p.string("owner") ?? "", commandLine: p.string("cmdLine") ?? "",
                                    started: p.date("startTime"), ended: p.date("endTime"), exitCode: p.int("exitCode"))
        }
    }

    /// Waits for a process started by this session to end (Tools keeps its record for 5 minutes).
    public func waitForProcess(_ pid: Int64, vm: MoRef, login: GuestLogin, timeout: TimeInterval = 600) async throws -> GuestProcessInfo? {
        let deadline = Date().addingTimeInterval(timeout)
        var delay: UInt64 = 250_000_000
        while Date() < deadline {
            let ps = try await listProcesses(vm: vm, login: login, pids: [pid])
            if let p = ps.first, p.ended != nil { return p }
            if ps.isEmpty { return nil }
            try await Task.sleep(nanoseconds: delay)
            delay = min(delay * 2, 1_000_000_000)
        }
        throw VimError.guestOperation("The program is still running after \(Int(timeout)) s")
    }

    // MARK: Helpers

    /// A shell to run things in, by guest family.
    public enum Shell: Sendable {
        case powershell, cmd, sh, bash, zsh, python

        public var title: String {
            switch self {
            case .powershell: "PowerShell"
            case .cmd: "cmd"
            case .sh: "sh"
            case .bash: "bash"
            case .zsh: "zsh"
            case .python: "python3"
            }
        }

        public static func `default`(for family: GuestFamily) -> Shell {
            switch family {
            case .windows: .powershell
            case .darwin: .zsh
            default: .sh
            }
        }

        /// Shell by script extension.
        public static func forScript(named name: String, family: GuestFamily) -> Shell {
            switch (name as NSString).pathExtension.lowercased() {
            case "ps1": .powershell
            case "bat", "cmd": .cmd
            case "sh": family == .windows ? .powershell : .sh
            case "bash": .bash
            case "zsh": .zsh
            case "py": .python
            default: .default(for: family)
            }
        }

        var scriptSuffix: String {
            switch self {
            case .powershell: ".ps1"
            case .cmd: ".cmd"
            case .sh, .bash, .zsh: ".sh"
            case .python: ".py"
            }
        }
    }

    public struct RunResult: Sendable {
        public var output: String
        public var exitCode: Int?
        public var duration: TimeInterval
    }

    /// Runs a command line (or a whole script) in the guest and returns what it printed. The
    /// script and its output go through temporary files in the guest's temp folder.
    public func run(_ script: String, shell: Shell, vm: MoRef, login: GuestLogin, family: GuestFamily,
                    workingDirectory: String? = nil, timeout: TimeInterval = 600) async throws -> RunResult {
        let start = Date()
        let scriptPath = try await createTemporaryFile(vm: vm, login: login, prefix: "labdock-", suffix: shell.scriptSuffix)
        let outPath = try await createTemporaryFile(vm: vm, login: login, prefix: "labdock-", suffix: ".out")
        defer {
            Task {
                try? await deleteFile(vm: vm, login: login, path: scriptPath)
                try? await deleteFile(vm: vm, login: login, path: outPath)
            }
        }
        var body = script
        if family == .windows, shell == .powershell {
            // Windows PowerShell 5 writes UTF-16 by default; ask for UTF-8 so the output reads back cleanly.
            body = "[Console]::OutputEncoding = [System.Text.Encoding]::UTF8\n$OutputEncoding = [System.Text.Encoding]::UTF8\n" + script
        }
        try await upload(Data(body.utf8), to: scriptPath, vm: vm, login: login, family: family, executable: true)
        let program: String
        let arguments: String
        switch (family, shell) {
        case (.windows, .powershell):
            program = "C:\\Windows\\System32\\cmd.exe"
            // -STA: the clipboard cmdlets want a single-threaded apartment.
            arguments = "/c \"\"C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe\" -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File \"\(scriptPath)\" > \"\(outPath)\" 2>&1\""
        case (.windows, .cmd):
            program = "C:\\Windows\\System32\\cmd.exe"
            arguments = "/c \"\"\(scriptPath)\" > \"\(outPath)\" 2>&1\""
        case (.windows, .python):
            program = "C:\\Windows\\System32\\cmd.exe"
            arguments = "/c \"python \"\(scriptPath)\" > \"\(outPath)\" 2>&1\""
        case (.windows, _):
            program = "C:\\Windows\\System32\\cmd.exe"
            arguments = "/c \"\"\(scriptPath)\" > \"\(outPath)\" 2>&1\""
        case (_, .python):
            program = "/bin/sh"
            arguments = "-c 'python3 \"\(scriptPath)\" > \"\(outPath)\" 2>&1'"
        case (_, .bash):
            program = "/bin/sh"
            arguments = "-c 'bash \"\(scriptPath)\" > \"\(outPath)\" 2>&1'"
        case (_, .zsh):
            program = "/bin/sh"
            arguments = "-c 'zsh \"\(scriptPath)\" > \"\(outPath)\" 2>&1'"
        default:
            program = "/bin/sh"
            arguments = "-c 'sh \"\(scriptPath)\" > \"\(outPath)\" 2>&1'"
        }
        let pid = try await startProgram(vm: vm, login: login, program: program, arguments: arguments, workingDirectory: workingDirectory)
        let proc = try await waitForProcess(pid, vm: vm, login: login, timeout: timeout)
        let data = try await download(outPath, vm: vm, login: login)
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return RunResult(output: text, exitCode: proc?.exitCode, duration: Date().timeIntervalSince(start))
    }

    /// Puts text on the guest's clipboard: the file goes up through Tools, a small program in
    /// the user's interactive session copies it.
    public func paste(_ text: String, vm: MoRef, login: GuestLogin, family: GuestFamily) async throws {
        var interactive = login
        interactive.interactive = true
        let path = try await createTemporaryFile(vm: vm, login: interactive, prefix: "labdock-clip-", suffix: ".txt")
        // UTF-8 with BOM so PowerShell 5 reads it as Unicode without an -Encoding switch surprise.
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(text.utf8))
        try await upload(data, to: path, vm: vm, login: interactive, family: family)
        let program: String
        let arguments: String
        var env: [String] = []
        switch family {
        case .windows:
            program = "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"
            arguments = "-NoProfile -NonInteractive -STA -Command \"Get-Content -Raw -Encoding UTF8 -LiteralPath '\(path)' | Set-Clipboard; Remove-Item -LiteralPath '\(path)'\""
        case .darwin:
            program = "/bin/sh"
            arguments = "-c 'pbcopy < \"\(path)\"; rm -f \"\(path)\"'"
        default:
            program = "/bin/sh"
            // Wayland first, then X11. The display comes from the guest session, not from
            // here: Tools passes on almost no environment, and the runtime dir belongs to
            // the guest user's own uid, not a hard-coded 1000.
            arguments = "-c 'DISPLAY=\"${DISPLAY:-:0}\"; WAYLAND_DISPLAY=\"${WAYLAND_DISPLAY:-wayland-0}\"; XDG_RUNTIME_DIR=\"${XDG_RUNTIME_DIR:-/run/user/$(id -u)}\"; export DISPLAY WAYLAND_DISPLAY XDG_RUNTIME_DIR; if command -v wl-copy >/dev/null 2>&1; then wl-copy < \"\(path)\"; elif command -v xclip >/dev/null 2>&1; then xclip -selection clipboard -i \"\(path)\"; elif command -v xsel >/dev/null 2>&1; then xsel --clipboard --input < \"\(path)\"; else exit 127; fi; rm -f \"\(path)\"'"
        }
        let pid = try await startProgram(vm: vm, login: interactive, program: program, arguments: arguments, environment: env)
        if let p = try await waitForProcess(pid, vm: vm, login: interactive, timeout: 60), let code = p.exitCode, code != 0 {
            let why = family == .windows ? "Set-Clipboard failed (exit \(code)); is the user logged in on the console?"
                : code == 127 ? "No clipboard tool in the guest (install wl-clipboard, xclip or xsel)"
                : "The clipboard program failed (exit \(code)); is a desktop session open?"
            throw VimError.guestOperation(why)
        }
    }

    /// The guest's temp folder, as a sensible first folder for the Files tab.
    public static func homeFolder(for family: GuestFamily, login: GuestLogin) -> String {
        switch family {
        case .windows:
            let user = login.username.split(separator: "\\").last.map(String.init) ?? login.username
            return "C:\\Users\\\(user)"
        case .darwin: return "/Users/\(login.username)"
        default: return login.username == "root" ? "/root" : "/home/\(login.username)"
        }
    }

    /// Joins a folder and a name the guest's way.
    public static func join(_ folder: String, _ name: String, family: GuestFamily) -> String {
        let sep = family == .windows ? "\\" : "/"
        if folder.hasSuffix(sep) { return folder + name }
        return folder + sep + name
    }

    public static func parent(of path: String, family: GuestFamily) -> String? {
        let sep: Character = family == .windows ? "\\" : "/"
        var p = path
        while p.count > 1, p.last == sep { p.removeLast() }
        guard let i = p.lastIndex(of: sep) else { return nil }
        let parent = String(p[..<i])
        if parent.isEmpty { return family == .windows ? nil : "/" }
        if family == .windows, parent.count == 2, parent.hasSuffix(":") { return parent + "\\" }
        return parent
    }
}
