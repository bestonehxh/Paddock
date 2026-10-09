import Foundation
import Testing
import VimClient

/// Windows events of the last LABDOCK_MINUTES minutes (System + Winlogon + Tools logs), to see
/// what locked the session.
@Test func liveWindowsRecentEvents() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let host = env["LABDOCK_HOST"], let user = env["LABDOCK_USER"], let pass = env["LABDOCK_PASS"],
          let name = env["LABDOCK_VM"], let guser = env["LABDOCK_GUEST_USER"], let gpass = env["LABDOCK_GUEST_PASS"] else { return }
    let minutes = env["LABDOCK_MINUTES"] ?? "12"
    let s = VimSession(host: host, username: user, password: pass, expectedThumbprint: nil)
    try await s.login()
    guard let vm = try await s.listVMs().first(where: { $0.name == name }) else { return }
    let login = GuestLogin(username: guser, password: gpass, interactive: false)
    let script = """
    $since = (Get-Date).AddMinutes(-\(minutes))
    'now: ' + (Get-Date)
    'LogonUI started: ' + ((Get-Process LogonUI -ErrorAction SilentlyContinue | Select-Object -First 1).StartTime)
    '--- System log ---'
    Get-WinEvent -FilterHashtable @{LogName='System'; StartTime=$since} -ErrorAction SilentlyContinue | Select-Object -First 40 | ForEach-Object { "$($_.TimeCreated.ToString('HH:mm:ss')) $($_.ProviderName) $($_.Id) $($_.Message -replace '\\s+',' ' | ForEach-Object { $_.Substring(0, [Math]::Min(110, $_.Length)) })" }
    '--- Winlogon ---'
    Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-Winlogon/Operational'; StartTime=$since} -ErrorAction SilentlyContinue | Select-Object -First 20 | ForEach-Object { "$($_.TimeCreated.ToString('HH:mm:ss')) $($_.Id) $($_.Message -replace '\\s+',' ' | ForEach-Object { $_.Substring(0, [Math]::Min(110, $_.Length)) })" }
    '--- Application log (VMware) ---'
    Get-WinEvent -FilterHashtable @{LogName='Application'; StartTime=$since} -ErrorAction SilentlyContinue | Where-Object { $_.ProviderName -like '*VMware*' -or $_.ProviderName -like '*Winlogon*' } | Select-Object -First 20 | ForEach-Object { "$($_.TimeCreated.ToString('HH:mm:ss')) $($_.ProviderName) $($_.Id) $($_.Message -replace '\\s+',' ' | ForEach-Object { $_.Substring(0, [Math]::Min(140, $_.Length)) })" }
    '--- Tools logs ---'
    Get-ChildItem 'C:\\ProgramData\\VMware\\VMware Tools\\*.log' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name; Get-Content $_.FullName -Tail 15 }
    """
    let r = try await s.run(script, shell: .powershell, vm: vm.ref, login: login, family: .windows, timeout: 90)
    print(r.output)
    await s.logout()
}
