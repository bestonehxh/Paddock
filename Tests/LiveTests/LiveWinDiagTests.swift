import Foundation
import Testing
import VimClient

/// Why does Windows lock when the console reopens? Reads the lock/sleep policy and the last
/// lock events through Tools (LABDOCK_VM, LABDOCK_GUEST_USER/PASS).
@Test func liveWindowsLockDiagnostics() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let host = env["LABDOCK_HOST"], let user = env["LABDOCK_USER"], let pass = env["LABDOCK_PASS"],
          let name = env["LABDOCK_VM"], let guser = env["LABDOCK_GUEST_USER"], let gpass = env["LABDOCK_GUEST_PASS"] else { return }
    let s = VimSession(host: host, username: user, password: pass, expectedThumbprint: nil)
    try await s.login()
    guard let vm = try await s.listVMs().first(where: { $0.name == name }) else { return }
    let login = GuestLogin(username: guser, password: gpass, interactive: true)
    let script = """
    'sleep after (AC/DC seconds):'; powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE | Select-String 'Power Setting Index'
    'hibernate after:'; powercfg /query SCHEME_CURRENT SUB_SLEEP HIBERNATEIDLE | Select-String 'Power Setting Index'
    'require password on wake (1=yes):'; powercfg /query SCHEME_CURRENT SUB_NONE CONSOLELOCK | Select-String 'Power Setting Index'
    'last sleep/wake:'; try { Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-Kernel-Power'; Id=42,107} -MaxEvents 10 -ErrorAction Stop | ForEach-Object { "$($_.TimeCreated)  $($_.Id) $(if($_.Id -eq 42){'sleep'}else{'wake'})" } } catch { "none" }
    'display off (AC/DC seconds):'; powercfg /query SCHEME_CURRENT SUB_VIDEO VIDEOIDLE | Select-String 'Power Setting Index'
    'screensaver:'; Get-ItemProperty 'HKCU:\\Control Panel\\Desktop' | Select-Object ScreenSaveActive, ScreenSaverIsSecure, ScreenSaveTimeOut | Format-List
    'inactivity policy:'; Get-ItemProperty 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System' -ErrorAction SilentlyContinue | Select-Object InactivityTimeoutSecs, DisableLockWorkstation | Format-List
    'require sign-in (DelayLockInterval):'; Get-ItemProperty 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Winlogon' -ErrorAction SilentlyContinue | Select-Object DelayLockInterval | Format-List
    'last locks (4800) / unlocks (4801):'
    try { Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4800,4801} -MaxEvents 8 -ErrorAction Stop | ForEach-Object { "$($_.TimeCreated)  $($_.Id)" } } catch { "no access to the Security log: $($_.Exception.Message)" }
    'last display changes / power events:'
    try { Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-Power-Troubleshooter','Microsoft-Windows-Kernel-Power','Display'} -MaxEvents 6 -ErrorAction Stop | ForEach-Object { "$($_.TimeCreated)  $($_.ProviderName) $($_.Id)" } } catch { "none: $($_.Exception.Message)" }
    'now:'; Get-Date
    'sessions:'; query user 2>&1
    """
    let r = try await s.run(script, shell: .powershell, vm: vm.ref, login: login, family: .windows, timeout: 90)
    print(r.output)
    await s.logout()
}
