import Foundation

/// Power, snapshots, tools, console tickets and keystrokes.
extension VimSession {
    public enum PowerAction: String, Sendable, CaseIterable {
        case powerOn, shutdownGuest, rebootGuest, suspend, powerOff, reset

        public var title: String {
            switch self {
            case .powerOn: "Power on"
            case .shutdownGuest: "Shut down guest"
            case .rebootGuest: "Reboot guest"
            case .suspend: "Suspend"
            case .powerOff: "Power off"
            case .reset: "Reset"
            }
        }
        /// Hard actions that lose unsaved guest state.
        public var destructive: Bool { self == .powerOff || self == .reset }
        public var needsTools: Bool { self == .shutdownGuest || self == .rebootGuest }
    }

    public func power(_ action: PowerAction, vm: MoRef) async throws {
        switch action {
        case .powerOn: try await runTask("PowerOnVM_Task", this: vm)
        case .powerOff: try await runTask("PowerOffVM_Task", this: vm)
        case .suspend: try await runTask("SuspendVM_Task", this: vm)
        case .reset: try await runTask("ResetVM_Task", this: vm)
        case .shutdownGuest: try await call("ShutdownGuest", this: vm)
        case .rebootGuest: try await call("RebootGuest", this: vm)
        }
    }

    // MARK: Snapshots

    public func createSnapshot(vm: MoRef, name: String, description: String, memory: Bool, quiesce: Bool) async throws {
        try await runTask("CreateSnapshot_Task", this: vm, [
            .text("name", name), .text("description", description), .bool("memory", memory), .bool("quiesce", quiesce),
        ])
    }

    public func revert(to snapshot: MoRef) async throws {
        try await runTask("RevertToSnapshot_Task", this: snapshot, [.bool("suppressPowerOn", false)])
    }

    public func removeSnapshot(_ snapshot: MoRef, removeChildren: Bool) async throws {
        try await runTask("RemoveSnapshot_Task", this: snapshot, [.bool("removeChildren", removeChildren), .bool("consolidate", true)])
    }

    public func removeAllSnapshots(vm: MoRef) async throws {
        try await runTask("RemoveAllSnapshots_Task", this: vm, [.bool("consolidate", true)])
    }

    // MARK: Tools

    public func mountToolsInstaller(vm: MoRef) async throws { try await call("MountToolsInstaller", this: vm) }
    public func unmountToolsInstaller(vm: MoRef) async throws { try await call("UnmountToolsInstaller", this: vm) }

    // MARK: Console

    /// A WebMKS ticket; the host in the ticket is usually empty on ESXi, so the session host is used.
    public func consoleTicket(vm: MoRef) async throws -> ConsoleTicket {
        let r = try await call("AcquireTicket", this: vm, [.text("ticketType", "webmks")])
        guard let rv = r["returnval"], let ticket = rv.string("ticket") else { throw VimError.malformedResponse("ticket") }
        let ticketHost = rv.string("host").flatMap { $0.isEmpty || $0 == "*" ? nil : $0 } ?? host
        return ConsoleTicket(ticket: ticket, host: ticketHost, port: rv.int("port") ?? 443, sslThumbprint: rv.string("sslThumbprint"))
    }

    // MARK: Keystrokes

    /// Sends strokes through the virtual USB keyboard (works without Tools). Returns how many
    /// the host accepted.
    @discardableResult
    public func sendKeystrokes(_ strokes: [HIDKey.Stroke], vm: MoRef) async throws -> Int {
        var sent = 0
        // ESXi accepts large batches, but keep them modest so a long paste shows progress.
        for chunk in stride(from: 0, to: strokes.count, by: 64).map({ Array(strokes[$0..<min($0 + 64, strokes.count)]) }) {
            let events = chunk.map { s -> XMLOut.Element in
                var children: [XMLOut.Element] = [.int("usbHidCode", Int(s.usbHidCode))]
                if s.shift || s.control || s.alt || s.gui {
                    var mods: [XMLOut.Element] = []
                    if s.control { mods.append(.bool("leftControl", true)) }
                    if s.shift { mods.append(.bool("leftShift", true)) }
                    if s.alt { mods.append(.bool("leftAlt", true)) }
                    if s.gui { mods.append(.bool("leftGui", true)) }
                    children.append(XMLOut.Element("modifiers", children: mods))
                }
                return XMLOut.Element("keyEvents", children: children)
            }
            let r = try await call("PutUsbScanCodes", this: vm, [XMLOut.Element("spec", children: events)])
            sent += r.int("returnval") ?? chunk.count
        }
        return sent
    }

    /// Types text on the console keyboard; characters outside the US layout are skipped and returned.
    @discardableResult
    public func type(_ text: String, vm: MoRef) async throws -> [Character] {
        var skipped: [Character] = []
        let strokes = HIDKey.strokes(for: text, skipped: &skipped)
        if !strokes.isEmpty { try await sendKeystrokes(strokes, vm: vm) }
        return skipped
    }
}

// MARK: - VM options (extraConfig)

extension VimSession {
    /// `tools.guest.desktop.autolock`: VMware's "Lock the guest operating system when the last
    /// remote user disconnects". ESXi sets it TRUE on new VMs; with it on, every console
    /// disconnect locks a Windows guest with Tools (owner's VMs, 3 Oct 2026).
    public static let autolockKey = "tools.guest.desktop.autolock"

    /// nil when the key isn't set (VMware's default behaviour then depends on the version).
    public func autolock(vm: MoRef) async throws -> Bool? {
        let objs = try await retrieveProperties(of: [vm], paths: ["config.extraConfig"])
        for e in objs.first?.props["config.extraConfig"]?.children ?? [] where e.string("key") == Self.autolockKey {
            return e.string("value")?.uppercased() == "TRUE"
        }
        return nil
    }

    /// Changes the option; takes effect at once for a powered-on VM with Tools.
    public func setAutolock(vm: MoRef, _ on: Bool) async throws {
        let option = XMLOut.Element.typed("extraConfig", "OptionValue", [.text("key", Self.autolockKey), .typed("value", "xsd:string", []).withText(on ? "TRUE" : "FALSE")])
        try await runTask("ReconfigVM_Task", this: vm, [XMLOut.Element("spec", children: [option])])
    }
}

extension XMLOut.Element {
    func withText(_ t: String) -> XMLOut.Element { var e = self; e.text = t; return e }
}
