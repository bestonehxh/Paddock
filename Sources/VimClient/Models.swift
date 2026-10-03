import Foundation

public enum PowerState: String, Sendable, Codable {
    case poweredOn, poweredOff, suspended
    public var word: String {
        switch self {
        case .poweredOn: "Running"
        case .poweredOff: "Off"
        case .suspended: "Suspended"
        }
    }
}

public enum ToolsStatus: Sendable, Hashable, Codable {
    case running(version: String?, current: Bool)
    case notRunning(installed: Bool)
    case unknown

    public var isRunning: Bool { if case .running = self { return true } else { return false } }

    public var word: String {
        switch self {
        case .running(let v, let current):
            var s = "Tools running"
            if let v { s += ", \(v)" }
            if !current { s += " (update available)" }
            return s
        case .notRunning(let installed): return installed ? "Tools not running" : "Tools not installed"
        case .unknown: return "Tools unknown"
        }
    }
}

public enum GuestFamily: String, Sendable, Codable {
    case windows = "windowsGuest"
    case linux = "linuxGuest"
    case darwin = "darwinGuest"
    case other = "otherGuestFamily"

    public init(guestId: String?, family: String?) {
        if let family, let f = GuestFamily(rawValue: family) { self = f; return }
        let id = (guestId ?? "").lowercased()
        if id.contains("windows") { self = .windows }
        else if id.contains("darwin") { self = .darwin }
        else if id.contains("linux") || id.contains("ubuntu") || id.contains("debian") || id.contains("centos")
                    || id.contains("rhel") || id.contains("sles") || id.contains("fedora") || id.contains("other") {
            self = id.contains("other") ? .other : .linux
        } else { self = .other }
    }
}

/// What the sidebar and Overview show for every VM; refreshed on every poll.
public struct VMSummary: Sendable, Identifiable, Hashable, Codable {
    public var ref: MoRef
    public var name: String
    public var powerState: PowerState
    public var ipAddress: String?
    public var hostName: String?
    public var tools: ToolsStatus
    public var guestFamily: GuestFamily
    public var guestFullName: String?
    public var guestId: String?
    public var numCPU: Int
    public var memoryMB: Int
    public var cpuUsageMHz: Int?
    public var guestMemoryUsageMB: Int?
    public var bootTime: Date?
    public var template: Bool
    public var currentSnapshot: MoRef?
    public var snapshots: [SnapshotNode]
    public var vmxPath: String?
    public var annotation: String?
    /// `connected` normally; `invalid`, `orphaned`, `inaccessible` or `disconnected` for a VM
    /// ESXi can't open (its datastore is gone, its files are missing).
    public var connectionState: String = "connected"

    public var id: String { ref.value }

    /// A VM ESXi can't open: no power actions, no console.
    public var inaccessible: Bool { connectionState != "connected" }

    /// What the sidebar shows: the power state, or why the VM can't be used.
    public var stateWord: String {
        switch connectionState {
        case "connected": powerState.word
        case "orphaned": "Orphaned"
        case "invalid": "Invalid"
        default: "Inaccessible"
        }
    }

    /// Whether guest operations (files, run, paste) can be attempted.
    public var canUseGuest: Bool { powerState == .poweredOn && tools.isRunning }
}

public struct SnapshotNode: Sendable, Identifiable, Hashable, Codable {
    public var ref: MoRef
    public var name: String
    public var description: String
    public var created: Date?
    public var powerState: PowerState?
    public var quiesced: Bool
    public var children: [SnapshotNode]
    public var id: String { ref.value }

    public func flattened(depth: Int = 0) -> [(node: SnapshotNode, depth: Int)] {
        [(self, depth)] + children.flatMap { $0.flattened(depth: depth + 1) }
    }
}

/// Details fetched only for the selected VM.
public struct VMDetail: Sendable, Hashable {
    public var disks: [Disk]
    public var nics: [NIC]
    public var cdroms: [CDROM]
    public var ipAddresses: [String]

    public struct Disk: Sendable, Hashable {
        public var label: String
        public var capacityBytes: Int64
        public var fileName: String
        public var thin: Bool
    }
    public struct NIC: Sendable, Hashable {
        public var label: String
        public var macAddress: String
        public var network: String
        public var connected: Bool
    }
    public struct CDROM: Sendable, Hashable {
        public var label: String
        public var backing: String
        public var connected: Bool
    }
}

public struct HostInfo: Sendable, Hashable {
    public var ref: MoRef
    public var name: String
    public var product: String
    public var apiVersion: String
    public var cpuModel: String
    public var cpuCores: Int
    public var cpuMHz: Int
    public var memoryBytes: Int64
    public var cpuUsageMHz: Int
    public var memoryUsageMB: Int
    public var uptimeSeconds: Int?
    public var datastores: [Datastore]
    public var connectionState: String
    public var inMaintenance: Bool
}

public struct Datastore: Sendable, Hashable, Identifiable {
    public var ref: MoRef
    public var name: String
    public var capacity: Int64
    public var free: Int64
    public var type: String
    public var id: String { ref.value }
}

public struct GuestFileInfo: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable { case file, directory, symlink }
    public var path: String
    public var kind: Kind
    public var size: Int64
    public var modified: Date?
    public var id: String { path }

    public init(path: String, kind: Kind, size: Int64, modified: Date?) {
        self.path = path
        self.kind = kind
        self.size = size
        self.modified = modified
    }
    public var name: String {
        let trimmed = path.hasSuffix("/") || path.hasSuffix("\\") ? String(path.dropLast()) : path
        if let i = trimmed.lastIndex(where: { $0 == "/" || $0 == "\\" }) { return String(trimmed[trimmed.index(after: i)...]) }
        return trimmed
    }
}

public struct GuestProcessInfo: Sendable, Hashable {
    public var pid: Int64
    public var name: String
    public var owner: String
    public var commandLine: String
    public var started: Date?
    public var ended: Date?
    public var exitCode: Int?
}

/// Credentials for guest operations: `interactive` runs the program on the user's desktop
/// session (needed for the clipboard), otherwise in a service session.
public struct GuestLogin: Sendable, Hashable {
    public var username: String
    public var password: String
    public var interactive: Bool

    public init(username: String, password: String, interactive: Bool = false) {
        self.username = username
        self.password = password
        self.interactive = interactive
    }
}

public struct ConsoleTicket: Sendable, Hashable {
    public var ticket: String
    public var host: String
    public var port: Int
    public var sslThumbprint: String?
    public var url: URL { URL(string: "wss://\(host):\(port)/ticket/\(ticket)")! }
}
