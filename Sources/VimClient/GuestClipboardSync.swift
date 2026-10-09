import Foundation

/// Two-way clipboard sharing with a guest over VMware Tools (what Fusion does with its own
/// agent): a small watcher runs in the guest's desktop session, writes every new guest clipboard
/// text to a file Paddock polls, and sets the guest clipboard from text Paddock uploads. One
/// extra second of latency, no guest network needed. Windows (PowerShell, STA) and Linux (xclip /
/// wl-clipboard / xsel) guests; macOS guests use pbcopy / pbpaste.
public actor GuestClipboardSync {
    public let session: VimSession
    public let vm: MoRef
    public let family: GuestFamily
    private let login: GuestLogin
    private var dir = ""
    /// The guest folder and watcher process, for diagnostics.
    public var directory: String { dir }
    public private(set) var processID: Int64?
    private var guestSeq = 0
    private var macSeq = 0
    public private(set) var started = false

    public init(session: VimSession, vm: MoRef, login: GuestLogin, family: GuestFamily) {
        self.session = session
        self.vm = vm
        var interactive = login
        interactive.interactive = true   // the clipboard lives in the desktop session
        self.login = interactive
        self.family = family
    }

    private var sep: String { family == .windows ? "\\" : "/" }
    private func path(_ name: String) -> String { dir + sep + name }

    public func start() async throws {
        guard !started else { return }
        dir = try await session.createTemporaryDirectory(vm: vm, login: login, prefix: "paddock-clip-")
        if family == .windows {
            let runner = path("watch.ps1")
            try await session.upload(Data(Self.windowsWatcher(dir: dir).utf8), to: runner, vm: vm, login: login, family: family)
            // Through cmd.exe so PowerShell's own errors land in watch.log for diagnosis.
            processID = try await session.startProgram(
                vm: vm, login: login, program: "C:\\Windows\\System32\\cmd.exe",
                arguments: "/c \"\"C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe\" -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File \"\(runner)\" > \"\(path("watch.log"))\" 2>&1\"")
        } else {
            let runner = path("watch.sh")
            try await session.upload(Data(Self.posixWatcher(dir: dir, darwin: family == .darwin).utf8), to: runner, vm: vm, login: login,
                                     family: family, executable: true)
            processID = try await session.startProgram(vm: vm, login: login, program: "/bin/sh", arguments: "\"\(runner)\" > \"\(path("watch.log"))\" 2>&1")
        }
        started = true
    }

    /// True once the watcher wrote its `up` marker (PowerShell takes 5–10 s to come up in a
    /// desktop session); polls until then or until the timeout.
    /// False when the guest has no clipboard tool (a Linux server without X11/Wayland): the
    /// watcher runs but can't carry anything, so the caller should type instead.
    public private(set) var guestHasClipboard = true

    public func waitUntilReady(timeout: TimeInterval = 20) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let up = try? await session.download(path("up"), vm: vm, login: login) {
                guestHasClipboard = !String(decoding: up, as: UTF8.self).contains("noclip")
                return true
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    /// The guest's clipboard text when it changed since the last call, nil otherwise.
    public func pollGuest() async throws -> String? {
        guard started else { return nil }
        let seqData: Data
        do {
            seqData = try await session.download(path("guest.seq"), vm: vm, login: login)
        } catch VimError.fault(let type, _) where type == "FileNotFound" || type == "FileFault" {
            return nil
        }
        guard let seq = Int(String(decoding: seqData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
              seq != guestSeq else { return nil }
        guestSeq = seq
        let text = try await session.download(path("guest.\(seq).txt"), vm: vm, login: login)
        var s = String(decoding: text, as: UTF8.self)
        if s.hasPrefix("\u{FEFF}") { s.removeFirst() }
        return s
    }

    /// Puts text on the guest's clipboard; returns once the watcher acknowledged it (or after
    /// `timeout`, false).
    @discardableResult
    public func push(_ text: String, timeout: TimeInterval = 3) async throws -> Bool {
        guard started else { return false }
        macSeq += 1
        let n = macSeq
        try await session.upload(Data(text.utf8), to: path("mac.\(n).txt"), vm: vm, login: login, family: family)
        try await session.upload(Data("1".utf8), to: path("mac.\(n).ready"), vm: vm, login: login, family: family)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(250))
            if let ack = try? await session.download(path("ack"), vm: vm, login: login),
               Int(String(decoding: ack, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) == n {
                return true
            }
        }
        return false
    }

    public func stop() async {
        guard started else { return }
        started = false
        try? await session.upload(Data("1".utf8), to: path("stop"), vm: vm, login: login, family: family)
        try? await Task.sleep(for: .milliseconds(700))
        try? await session.deleteDirectory(vm: vm, login: login, path: dir)
    }

    // MARK: Watchers

    static func windowsWatcher(dir: String) -> String {
        """
        $D = '\(dir)'
        Add-Type -AssemblyName System.Windows.Forms
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [IO.File]::WriteAllText((Join-Path $D 'up'), '1', $utf8)
        $seq = 0; $last = $null
        while ((Test-Path $D) -and -not (Test-Path (Join-Path $D 'stop'))) {
          try { $t = [System.Windows.Forms.Clipboard]::GetText() } catch { $t = $null }
          if ($t -ne $null -and $t -ne '' -and $t -ne $last) {
            $last = $t; $seq++
            [IO.File]::WriteAllText((Join-Path $D "guest.$seq.txt"), $t, $utf8)
            Remove-Item (Join-Path $D ("guest." + ($seq - 1) + ".txt")) -ErrorAction SilentlyContinue
            [IO.File]::WriteAllText((Join-Path $D 'guest.seq'), "$seq", $utf8)
          }
          $m = Get-ChildItem (Join-Path $D 'mac.*.ready') -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -First 1
          if ($m) {
            $n = $m.Name.Split('.')[1]
            $txt = Join-Path $D "mac.$n.txt"
            try {
              $text = [IO.File]::ReadAllText($txt, $utf8)
              [System.Windows.Forms.Clipboard]::SetText($text)
              $last = $text
            } catch {}
            Remove-Item $txt, $m.FullName -ErrorAction SilentlyContinue
            [IO.File]::WriteAllText((Join-Path $D 'ack'), "$n", $utf8)
          }
          Start-Sleep -Milliseconds 300
        }
        """
    }

    static func posixWatcher(dir: String, darwin: Bool) -> String {
        let get = darwin ? "pbpaste"
            : "if command -v wl-paste >/dev/null 2>&1; then wl-paste -n 2>/dev/null; elif command -v xclip >/dev/null 2>&1; then xclip -o -selection clipboard 2>/dev/null; else xsel -ob 2>/dev/null; fi"
        let set = darwin ? "pbcopy"
            : "if command -v wl-copy >/dev/null 2>&1; then wl-copy; elif command -v xclip >/dev/null 2>&1; then xclip -selection clipboard -i; else xsel --clipboard --input; fi"
        return """
        #!/bin/sh
        D='\(dir)'
        # Tools passes on almost no environment: the desktop session's display is resolved in
        # the guest, and the runtime dir belongs to the user's uid, not a hard-coded 1000.
        DISPLAY="${DISPLAY:-:0}"; export DISPLAY
        WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"; export WAYLAND_DISPLAY
        XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"; export XDG_RUNTIME_DIR
        seq=0
        : > "$D/last"
        if command -v wl-paste >/dev/null 2>&1 || command -v xclip >/dev/null 2>&1 || command -v xsel >/dev/null 2>&1 || command -v pbpaste >/dev/null 2>&1; then echo clip > "$D/up"; else echo noclip > "$D/up"; fi
        while [ -d "$D" ] && [ ! -e "$D/stop" ]; do
          (\(get)) > "$D/now" 2>/dev/null
          if [ -s "$D/now" ] && ! cmp -s "$D/now" "$D/last"; then
            seq=$((seq+1)); cp "$D/now" "$D/guest.$seq.txt"; cp "$D/now" "$D/last"
            rm -f "$D/guest.$((seq-1)).txt"; echo "$seq" > "$D/guest.seq"
          fi
          m=$(ls "$D"/mac.*.ready 2>/dev/null | sort | head -n 1)
          if [ -n "$m" ]; then
            n=$(basename "$m" | cut -d. -f2)
            (\(set)) < "$D/mac.$n.txt" 2>/dev/null
            cp "$D/mac.$n.txt" "$D/last"
            rm -f "$D/mac.$n.txt" "$m"; echo "$n" > "$D/ack"
          fi
          sleep 0.3
        done
        """
    }
}
