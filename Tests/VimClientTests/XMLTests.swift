import Foundation
import Testing
@testable import VimClient

@Test func parsesServiceContent() throws {
    let xml = """
    <?xml version="1.0"?><soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
    <soapenv:Body><RetrieveServiceContentResponse xmlns="urn:vim25"><returnval><rootFolder type="Folder">ha-folder-root</rootFolder>
    <about><fullName>VMware ESXi 8.0.2 build-22380479</fullName></about></returnval></RetrieveServiceContentResponse></soapenv:Body></soapenv:Envelope>
    """
    let root = try XMLNode.parse(Data(xml.utf8))
    let rv = root.path("Body", "RetrieveServiceContentResponse", "returnval")
    #expect(MoRef(node: rv?["rootFolder"]) == MoRef(type: "Folder", value: "ha-folder-root"))
    #expect(rv?["about"]?.string("fullName") == "VMware ESXi 8.0.2 build-22380479")
}

@Test func escapesAndRendersEnvelope() {
    let data = XMLOut.envelope(method: "Login", this: MoRef(type: "SessionManager", value: "ha-sessionmgr"),
                               arguments: [.text("userName", "root"), .text("password", "a<b&\"c\"")])
    let s = String(decoding: data, as: UTF8.self)
    #expect(s.contains("<Login xmlns=\"urn:vim25\"><_this type=\"SessionManager\">ha-sessionmgr</_this>"))
    #expect(s.contains("<password>a&lt;b&amp;\"c\"</password>"))
}

@Test func faultTypeIsStripped() throws {
    let xml = """
    <soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
    <soapenv:Body><soapenv:Fault><faultcode>ServerFaultCode</faultcode><faultstring>Cannot complete login due to an incorrect user name or password.</faultstring>
    <detail><InvalidLoginFault xmlns="urn:vim25" xsi:type="InvalidLogin"></InvalidLoginFault></detail></soapenv:Fault></soapenv:Body></soapenv:Envelope>
    """
    let root = try XMLNode.parse(Data(xml.utf8))
    let fault = root.path("Body", "Fault")
    #expect(fault?["detail"]?.children.first?.xsiType == "InvalidLogin")
}

@Test func keystrokesCoverASCII() {
    var skipped: [Character] = []
    let strokes = HIDKey.strokes(for: "Hi, a1!\nก", skipped: &skipped)
    #expect(strokes.count == 8)
    #expect(strokes[0].shift && strokes[0].code == 0x0B)
    #expect(strokes[6].shift && strokes[6].code == 0x1E)
    #expect(strokes[7].code == HIDKey.enter)
    #expect(skipped == ["ก"])
    #expect(HIDKey.Stroke(code: 0x04).usbHidCode == 0x04 << 16 | 7)
}

@Test func guestPaths() {
    #expect(VimSession.parent(of: "C:\\Users\\lab\\Desktop", family: .windows) == "C:\\Users\\lab")
    #expect(VimSession.parent(of: "C:\\Users", family: .windows) == "C:\\")
    #expect(VimSession.parent(of: "C:\\", family: .windows) == nil)
    #expect(VimSession.parent(of: "/home/u", family: .linux) == "/home")
    #expect(VimSession.parent(of: "/home", family: .linux) == "/")
    #expect(VimSession.join("C:\\", "x", family: .windows) == "C:\\x")
    #expect(GuestFileInfo(path: "C:\\Users\\lab\\a.txt", kind: .file, size: 1, modified: nil).name == "a.txt")
}

/// Against a real host when PADDOCK_HOST / PADDOCK_USER / PADDOCK_PASS are set.
@Test func liveInventory() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let host = env["PADDOCK_HOST"], let user = env["PADDOCK_USER"], let pass = env["PADDOCK_PASS"] else { return }
    let s = VimSession(host: host, username: user, password: pass, expectedThumbprint: nil)
    let content = try await s.login()
    print("connected:", content.fullName, "thumbprint:", await s.transport.observedThumbprint?.sha1 ?? "-")
    let hostInfo = try await s.hostInfo()
    print("host:", hostInfo.name, hostInfo.cpuModel, hostInfo.cpuCores, "cores", hostInfo.memoryBytes / 1_073_741_824, "GB",
          hostInfo.datastores.map { "\($0.name) \($0.free / 1_073_741_824)/\($0.capacity / 1_073_741_824) GB" })
    let vms = try await s.listVMs()
    print("vms:", vms.count)
    for vm in vms.prefix(50) {
        print(" ", vm.ref.value, vm.name, vm.powerState.word, vm.guestFamily, vm.tools.word, vm.ipAddress ?? "-",
              "\(vm.numCPU) vCPU \(vm.memoryMB) MB", vm.snapshots.isEmpty ? "" : "snapshots: \(vm.snapshots.flatMap { $0.flattened() }.count)")
    }
    if let on = vms.first(where: { $0.powerState == .poweredOn }) {
        let d = try await s.detail(of: on.ref)
        print("detail of", on.name, d.disks.map { "\($0.label) \($0.capacityBytes / 1_073_741_824) GB thin=\($0.thin)" }, d.nics.map { "\($0.label) \($0.macAddress) \($0.network)" }, d.cdroms, d.ipAddresses)
        let t = try await s.consoleTicket(vm: on.ref)
        print("ticket:", t.url, t.sslThumbprint ?? "")
    }
    await s.logout()
}

@Test func inaccessibleVMNames() {
    #expect(VimSession.displayName("/vmfs/volumes/3a721637-df1a3d47/Win10_2/Win10_2.vmx") == "Win10_2")
    #expect(VimSession.displayName("Lab-Palo") == "Lab-Palo")
    #expect(SOAPTransport.TrustDelegate.display("2a905367d6639dff95769199f46c24131b0a7064") == "2A:90:53:67:D6:63:9D:FF:95:76:91:99:F4:6C:24:13:1B:0A:70:64")
}
