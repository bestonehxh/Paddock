import Foundation
import Testing
import VimClient

/// Stops leftover LabDock clipboard watchers in a Windows guest (LABDOCK_WIN_CLEANUP=1).
@Test func liveWindowsWatcherCleanup() async throws {
    let env = ProcessInfo.processInfo.environment
    guard env["LABDOCK_WIN_CLEANUP"] == "1", let host = env["LABDOCK_HOST"], let user = env["LABDOCK_USER"], let pass = env["LABDOCK_PASS"],
          let name = env["LABDOCK_VM"], let guser = env["LABDOCK_GUEST_USER"], let gpass = env["LABDOCK_GUEST_PASS"] else { return }
    let s = VimSession(host: host, username: user, password: pass, expectedThumbprint: nil)
    try await s.login()
    guard let vm = try await s.listVMs().first(where: { $0.name == name }) else { return }
    let login = GuestLogin(username: guser, password: gpass, interactive: true)
    let script = """
    $ps = Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*labdock-clip*' -or $_.CommandLine -like '*labdock-shell*' }
    foreach ($p in $ps) { "stopping $($p.ProcessId): $($p.CommandLine.Substring(0, [Math]::Min(90, $p.CommandLine.Length)))"; Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    "leftover folders:"; Get-ChildItem "$env:TEMP\\vmware-$env:USERNAME" -Directory -Filter 'labdock-*' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName; Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    "done"
    """
    let r = try await s.run(script, shell: .powershell, vm: vm.ref, login: login, family: .windows, timeout: 60)
    print(r.output)
    await s.logout()
}
