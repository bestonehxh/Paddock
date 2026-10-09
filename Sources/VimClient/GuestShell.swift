import Foundation

/// A persistent shell inside a guest, run over VMware Tools alone (no guest network needed).
///
/// How it works: a small runner script is uploaded to a temporary folder in the guest and
/// started as the saved guest user. It feeds an interactive `bash` (or `sh`, or PowerShell on
/// Windows) from numbered command files that LabDock uploads, and the shell's combined output
/// lands in `out`, which LabDock downloads and diffs every poll. State (cwd, variables, sudo
/// timestamps) survives between commands because it is one shell process. Round trip is about
/// one second; full-screen programs (vi, top) don't work since stdin isn't a terminal.
public actor GuestShell {
    public let session: VimSession
    public let vm: MoRef
    public let family: GuestFamily
    private let login: GuestLogin
    private var dir = ""
    private var pid: Int64?
    private var nextCommand = 1
    private var outputOffset = 0
    public private(set) var started = false
    public private(set) var ended = false

    public init(session: VimSession, vm: MoRef, login: GuestLogin, family: GuestFamily) {
        self.session = session
        self.vm = vm
        self.login = login
        self.family = family
    }

    private var sep: String { family == .windows ? "\\" : "/" }
    private func path(_ name: String) -> String { dir + sep + name }

    /// Creates the guest folder, uploads the runner and starts the shell.
    public func start() async throws {
        guard !started else { return }
        dir = try await session.createTemporaryDirectory(vm: vm, login: login, prefix: "labdock-shell-")
        if family == .windows {
            try await session.makeDirectory(vm: vm, login: login, path: path("cmd"))
            let runner = Self.windowsRunner(dir: dir)
            let runnerPath = path("run.ps1")
            try await session.upload(Data(runner.utf8), to: runnerPath, vm: vm, login: login, family: family)
            pid = try await session.startProgram(
                vm: vm, login: login, program: "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
                arguments: "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"\(runnerPath)\"")
        } else {
            let runner = Self.posixRunner(dir: dir, shell: family == .darwin ? "/bin/zsh" : "bash")
            let runnerPath = path("run.sh")
            try await session.upload(Data(runner.utf8), to: runnerPath, vm: vm, login: login, family: family, executable: true)
            pid = try await session.startProgram(vm: vm, login: login, program: "/bin/sh", arguments: "\"\(runnerPath)\"")
        }
        started = true
    }

    /// Queues one command (a line or a whole script) for the shell.
    public func send(_ command: String) async throws {
        guard started, !ended else { throw VimError.guestOperation("The shell isn't running") }
        let n = nextCommand
        nextCommand += 1
        let name = String(format: "%06d", n)
        var body = command
        if !body.hasSuffix("\n") { body += "\n" }
        if family == .windows { body = body.replacingOccurrences(of: "\n", with: "\r\n") }
        try await session.upload(Data(body.utf8), to: path("cmd\(sep)\(name)"), vm: vm, login: login, family: family)
        // The marker tells the runner the command file is complete.
        try await session.upload(Data("1".utf8), to: path("cmd\(sep)\(name).ready"), vm: vm, login: login, family: family)
    }

    /// New output since the last poll (empty when nothing happened). Sets `ended` when the
    /// shell exited (the user typed `exit`, or the runner stopped). Asks the host for the file
    /// from the last offset on, so a long session doesn't re-download everything it has ever
    /// printed; a host that ignores the Range header still works (the whole file is diffed).
    public func poll() async throws -> String {
        guard started else { return "" }
        let result: (data: Data, partial: Bool)
        do {
            result = try await session.download(path("out"), from: Int64(outputOffset), vm: vm, login: login)
        } catch VimError.fault(let type, _) where type == "FileNotFound" || type == "FileFault" {
            return ""   // the shell hasn't written anything yet
        }
        let chunk: Data
        if result.partial {
            chunk = result.data
        } else {
            guard result.data.count != outputOffset else { return "" }
            if result.data.count < outputOffset { outputOffset = 0 }   // the file was replaced
            chunk = result.data[outputOffset...]
        }
        outputOffset += chunk.count
        var text = String(decoding: chunk, as: UTF8.self)
        if text.contains("[labdock shell ended]") { ended = true }
        if family == .windows { text = text.replacingOccurrences(of: "\r\n", with: "\n") }
        return text
    }

    /// Asks the runner to stop and removes the folder.
    public func stop() async {
        guard started else { return }
        started = false
        try? await session.upload(Data("1".utf8), to: path("stop"), vm: vm, login: login, family: family)
        try? await Task.sleep(for: .milliseconds(600))
        try? await session.deleteDirectory(vm: vm, login: login, path: dir)
    }

    // MARK: Runners

    /// POSIX: numbered command files are fed, in order, to one interactive shell.
    static func posixRunner(dir: String, shell: String) -> String {
        """
        #!/bin/sh
        D='\(dir)'
        mkdir -p "$D/cmd"
        n=1
        feed() {
          while :; do
            f="$D/cmd/$(printf %06d $n)"
            if [ -f "$f.ready" ]; then
              cat "$f"; rm -f "$f" "$f.ready"; n=$((n+1))
            elif [ -f "$D/stop" ] || [ ! -d "$D" ]; then
              return 0
            else
              sleep 0.2
            fi
          done
        }
        cd "$HOME" 2>/dev/null
        if command -v \(shell) >/dev/null 2>&1; then SH=\(shell); else SH=sh; fi
        feed | "$SH" -i > "$D/out" 2>&1
        echo '[labdock shell ended]' >> "$D/out"
        """
    }

    /// Windows: PowerShell keeps one session and runs each command file in it.
    static func windowsRunner(dir: String) -> String {
        """
        $D = '\(dir)'
        $out = Join-Path $D 'out'
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        Set-Location $env:USERPROFILE
        "PS $PWD> " | Out-File -FilePath $out -Encoding utf8 -NoNewline
        $n = 1
        while ($true) {
          $f = Join-Path $D ('cmd\\{0:d6}' -f $n)
          if (Test-Path "$f.ready") {
            $cmd = Get-Content -Raw -LiteralPath $f
            Remove-Item -LiteralPath $f, "$f.ready" -ErrorAction SilentlyContinue
            $n++
            $cmd | Out-File -FilePath $out -Append -Encoding utf8
            try { Invoke-Expression $cmd 2>&1 | Out-String -Width 200 | Out-File -FilePath $out -Append -Encoding utf8 }
            catch { $_ | Out-String | Out-File -FilePath $out -Append -Encoding utf8 }
            "PS $PWD> " | Out-File -FilePath $out -Append -Encoding utf8 -NoNewline
          } elseif ((Test-Path (Join-Path $D 'stop')) -or -not (Test-Path $D)) {
            break
          } else {
            Start-Sleep -Milliseconds 200
          }
        }
        '[labdock shell ended]' | Out-File -FilePath $out -Append -Encoding utf8
        """
    }
}
