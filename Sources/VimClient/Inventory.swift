import Foundation

/// VM and host inventory: the light property set for polling, details for one VM.
extension VimSession {
    public static let summaryPaths = [
        "name", "runtime.powerState", "runtime.bootTime", "guest.ipAddress", "guest.hostName",
        "guest.toolsRunningStatus", "guest.toolsVersionStatus2", "guest.toolsVersion", "guest.toolsStatus",
        "guest.guestFamily", "guest.guestFullName", "config.guestId", "config.guestFullName",
        "config.hardware.numCPU", "config.hardware.memoryMB", "config.template", "config.files.vmPathName",
        "config.annotation", "summary.quickStats.overallCpuUsage", "summary.quickStats.guestMemoryUsage",
        "snapshot", "runtime.connectionState",
    ]

    /// Every VM on the host.
    public func listVMs() async throws -> [VMSummary] {
        let objects = try await retrieveAll(type: "VirtualMachine", paths: Self.summaryPaths)
        return objects.compactMap(Self.summary(from:)).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// One VM, refreshed.
    public func summary(of vm: MoRef) async throws -> VMSummary? {
        try await retrieveProperties(of: [vm], paths: Self.summaryPaths).first.flatMap(Self.summary(from:))
    }

    static func summary(from o: ObjectContent) -> VMSummary? {
        guard let rawName = o.string("name"), let ps = o.string("runtime.powerState").flatMap(PowerState.init(rawValue:)) else {
            return nil
        }
        // An inaccessible VM has no config: ESXi reports its .vmx path as the name.
        let name = Self.displayName(rawName)
        let running = o.string("guest.toolsRunningStatus")
        let versionStatus = o.string("guest.toolsVersionStatus2") ?? o.string("guest.toolsStatus")
        let tools: ToolsStatus
        if running == "guestToolsRunning" {
            let current = versionStatus == "guestToolsCurrent" || versionStatus == "guestToolsUnmanaged"
                || versionStatus == "guestToolsSupportedNew" || versionStatus == "guestToolsOk"
            tools = .running(version: o.string("guest.toolsVersion").flatMap(Self.toolsVersionString), current: current)
        } else if running == "guestToolsNotRunning" || running == "guestToolsExecutingScripts" {
            tools = .notRunning(installed: versionStatus != "guestToolsNotInstalled")
        } else {
            tools = .unknown
        }
        let guestId = o.string("config.guestId")
        let family = GuestFamily(guestId: guestId, family: o.string("guest.guestFamily"))
        var current: MoRef?
        var roots: [SnapshotNode] = []
        if let snap = o.props["snapshot"] {
            current = MoRef(node: snap["currentSnapshot"])
            roots = snap.all("rootSnapshotList").compactMap(Self.snapshotNode)
        }
        let ip = o.string("guest.ipAddress").flatMap { $0.isEmpty ? nil : $0 }
        return VMSummary(
            ref: o.obj, name: name, powerState: ps, ipAddress: ip,
            hostName: o.string("guest.hostName").flatMap { $0.isEmpty ? nil : $0 },
            tools: tools, guestFamily: family,
            guestFullName: o.string("guest.guestFullName").flatMap { $0.isEmpty ? nil : $0 } ?? o.string("config.guestFullName"),
            guestId: guestId,
            numCPU: o.int("config.hardware.numCPU") ?? 0, memoryMB: o.int("config.hardware.memoryMB") ?? 0,
            cpuUsageMHz: o.int("summary.quickStats.overallCpuUsage"),
            guestMemoryUsageMB: o.int("summary.quickStats.guestMemoryUsage"),
            bootTime: o.date("runtime.bootTime"), template: o.bool("config.template") ?? false,
            currentSnapshot: current, snapshots: roots, vmxPath: o.string("config.files.vmPathName") ?? (rawName != name ? rawName : nil),
            annotation: o.string("config.annotation").flatMap { $0.isEmpty ? nil : $0 },
            connectionState: o.string("runtime.connectionState") ?? "connected")
    }

    /// `/vmfs/volumes/…/Win10_2/Win10_2.vmx` → `Win10_2`; anything else unchanged.
    static func displayName(_ name: String) -> String {
        guard name.hasPrefix("/vmfs/") || name.hasSuffix(".vmx") else { return name }
        let last = name.split(separator: "/").last.map(String.init) ?? name
        return last.hasSuffix(".vmx") ? String(last.dropLast(4)) : last
    }

    /// `12352` → `12.3.52`? Tools reports `major*1024 + minor*32 + patch` as a string; show as is
    /// when it doesn't fit that form.
    static func toolsVersionString(_ s: String) -> String {
        guard let n = Int(s), n > 1024 else { return s }
        return "\(n / 1024).\((n % 1024) / 32).\(n % 32)"
    }

    static func snapshotNode(_ n: XMLNode) -> SnapshotNode? {
        guard let ref = MoRef(node: n["snapshot"]), let name = n.string("name") else { return nil }
        return SnapshotNode(ref: ref, name: name, description: n.string("description") ?? "",
                            created: n.date("createTime"),
                            powerState: n.string("state").flatMap(PowerState.init(rawValue:)),
                            quiesced: n.bool("quiesced") ?? false,
                            children: n.all("childSnapshotList").compactMap(Self.snapshotNode))
    }

    /// Hardware details of one VM.
    public func detail(of vm: MoRef) async throws -> VMDetail {
        let objs = try await retrieveProperties(of: [vm], paths: ["config.hardware.device", "guest.net", "network"])
        guard let o = objs.first else { throw VimError.malformedResponse("VM detail") }
        var disks: [VMDetail.Disk] = []
        var nics: [VMDetail.NIC] = []
        var cdroms: [VMDetail.CDROM] = []
        // Network names come as references; label them by name where the guest reports them.
        var netNames: [String: String] = [:]
        for net in o.props["guest.net"]?.all("GuestNicInfo") ?? [] {
            if let mac = net.string("macAddress"), let name = net.string("network") { netNames[mac.lowercased()] = name }
        }
        for d in o.props["config.hardware.device"]?.children ?? [] {
            let type = d.xsiType ?? ""
            let label = d["deviceInfo"]?.string("label") ?? type
            if type == "VirtualDisk" {
                let backing = d["backing"]
                disks.append(.init(label: label, capacityBytes: d.int64("capacityInBytes") ?? (d.int64("capacityInKB") ?? 0) * 1024,
                                   fileName: backing?.string("fileName") ?? "", thin: backing?.bool("thinProvisioned") ?? false))
            } else if type.hasPrefix("VirtualVmxnet") || type.hasPrefix("VirtualE1000") || type == "VirtualPCNet32"
                        || type == "VirtualSriovEthernetCard" {
                let mac = d.string("macAddress") ?? ""
                let summary = d["deviceInfo"]?.string("summary") ?? ""
                let backingName = d["backing"]?.string("deviceName") ?? ""
                nics.append(.init(label: label, macAddress: mac,
                                  network: netNames[mac.lowercased()] ?? (backingName.isEmpty ? summary : backingName),
                                  connected: d["connectable"]?.bool("connected") ?? false))
            } else if type == "VirtualCdrom" {
                let backingType = d["backing"]?.xsiType ?? ""
                let what: String
                if backingType.contains("Iso") { what = d["backing"]?.string("fileName") ?? "ISO" }
                else if backingType.contains("Remote") { what = "Client device" }
                else { what = d["backing"]?.string("deviceName") ?? "Host device" }
                cdroms.append(.init(label: label, backing: what, connected: d["connectable"]?.bool("connected") ?? false))
            }
        }
        var ips: [String] = []
        for net in o.props["guest.net"]?.all("GuestNicInfo") ?? [] {
            ips += net.all("ipAddress").map(\.trimmedText).filter { !$0.isEmpty }
        }
        return VMDetail(disks: disks, nics: nics, cdroms: cdroms, ipAddresses: ips)
    }

    // MARK: - Host

    public func hostInfo() async throws -> HostInfo {
        let hosts = try await retrieveAll(type: "HostSystem", paths: [
            "name", "summary.config.product.fullName", "summary.config.product.apiVersion",
            "summary.hardware.cpuModel", "summary.hardware.numCpuCores", "summary.hardware.cpuMhz",
            "summary.hardware.memorySize", "summary.quickStats.overallCpuUsage", "summary.quickStats.overallMemoryUsage",
            "summary.quickStats.uptime", "summary.runtime.connectionState", "summary.runtime.inMaintenanceMode", "datastore",
        ])
        guard let h = hosts.first else { throw VimError.malformedResponse("HostSystem") }
        var datastores: [Datastore] = []
        let dsRefs = h.props["datastore"]?.children.compactMap { MoRef(node: $0) } ?? []
        if !dsRefs.isEmpty {
            let ds = try await retrieveProperties(of: dsRefs, paths: ["summary.name", "summary.capacity", "summary.freeSpace", "summary.type"])
            datastores = ds.map {
                Datastore(ref: $0.obj, name: $0.string("summary.name") ?? $0.obj.value,
                          capacity: $0.int64("summary.capacity") ?? 0, free: $0.int64("summary.freeSpace") ?? 0,
                          type: $0.string("summary.type") ?? "")
            }.sorted { $0.name < $1.name }
        }
        return HostInfo(
            ref: h.obj, name: h.string("name") ?? host,
            product: h.string("summary.config.product.fullName") ?? "", apiVersion: h.string("summary.config.product.apiVersion") ?? "",
            cpuModel: h.string("summary.hardware.cpuModel")?.trimmingCharacters(in: .whitespaces) ?? "",
            cpuCores: h.int("summary.hardware.numCpuCores") ?? 0, cpuMHz: h.int("summary.hardware.cpuMhz") ?? 0,
            memoryBytes: h.int64("summary.hardware.memorySize") ?? 0,
            cpuUsageMHz: h.int("summary.quickStats.overallCpuUsage") ?? 0, memoryUsageMB: h.int("summary.quickStats.overallMemoryUsage") ?? 0,
            uptimeSeconds: h.int("summary.quickStats.uptime"), datastores: datastores,
            connectionState: h.string("summary.runtime.connectionState") ?? "", inMaintenance: h.bool("summary.runtime.inMaintenanceMode") ?? false)
    }
}
