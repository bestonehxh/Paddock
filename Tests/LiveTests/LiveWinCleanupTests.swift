import Foundation
import Testing
import VimClient

/// Stops leftover Paddock clipboard watchers in a Windows guest (PADDOCK_WIN_CLEANUP=1).
@Test func liveWindowsWatcherCleanup() async throws {
    let env = ProcessInfo.processInfo.environment
    guard env["PADDOCK_WIN_CLEANUP"] == "1", let host = env["PADDOCK_HOST"], let user = env["PADDOCK_USER"], let pass = env["PADDOCK_PASS"],
          let name = env["PADDOCK_VM"], let guser = env["PADDOCK_GUEST_USER"], let gpass = env["PADDOCK_GUEST_PASS"] else { return }
    let s = VimSession(host: host, username: user, password: pass, expectedThumbprint: nil)
    try await s.login()
    guard let vm = try await s.listVMs().first(where: { $0.name == name }) else { return }
    let login = GuestLogin(username: guser, password: gpass, interactive: true)
    let script = """
    $ps = Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*paddock-clip*' -or $_.CommandLine -like '*paddock-shell*' }
    foreach ($p in $ps) { "stopping $($p.ProcessId): $($p.CommandLine.Substring(0, [Math]::Min(90, $p.CommandLine.Length)))"; Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    "leftover folders:"; Get-ChildItem "$env:TEMP\\vmware-$env:USERNAME" -Directory -Filter 'paddock-*' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName; Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    "done"
    """
    let r = try await s.run(script, shell: .powershell, vm: vm.ref, login: login, family: .windows, timeout: 60)
    print(r.output)
    await s.logout()
}
