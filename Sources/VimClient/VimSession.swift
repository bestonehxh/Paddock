import Foundation

/// One logged-in session with one ESXi host. Methods re-login once when the session has
/// expired (`NotAuthenticated`) and replay the call.
public actor VimSession {
    public nonisolated let transport: SOAPTransport
    public nonisolated let host: String
    private let username: String
    private let password: String
    private(set) var content: ServiceContent?
    public private(set) var isLoggedIn = false

    public struct ServiceContent: Sendable {
        public var rootFolder: MoRef
        public var propertyCollector: MoRef
        public var viewManager: MoRef
        public var sessionManager: MoRef
        public var guestOperationsManager: MoRef?
        public var fileManager: MoRef?
        public var fullName: String
        public var apiVersion: String
        public var version: String
        public var build: String
        public var hostName: String?
    }

    public init(host: String, port: Int = 443, username: String, password: String, expectedThumbprint: String?) {
        self.host = host
        self.username = username
        self.password = password
        transport = SOAPTransport(host: host, port: port, expectedThumbprint: expectedThumbprint)
    }

    public var serviceContent: ServiceContent? { content }

    // MARK: - Session

    @discardableResult
    public func login() async throws -> ServiceContent {
        let rsc = try await transport.call("RetrieveServiceContent", this: .serviceInstance)
        guard let rv = rsc["returnval"],
              let root = MoRef(node: rv["rootFolder"]),
              let pc = MoRef(node: rv["propertyCollector"]),
              let vm = MoRef(node: rv["viewManager"]),
              let sm = MoRef(node: rv["sessionManager"]) else {
            throw VimError.malformedResponse("ServiceContent")
        }
        let about = rv["about"]
        var c = ServiceContent(rootFolder: root, propertyCollector: pc, viewManager: vm, sessionManager: sm,
                               guestOperationsManager: MoRef(node: rv["guestOperationsManager"]),
                               fileManager: MoRef(node: rv["fileManager"]),
                               fullName: about?.string("fullName") ?? "VMware ESXi",
                               apiVersion: about?.string("apiVersion") ?? "8.0.2.0",
                               version: about?.string("version") ?? "",
                               build: about?.string("build") ?? "", hostName: nil)
        _ = try await transport.call("Login", this: sm, [.text("userName", username), .text("password", password)])
        isLoggedIn = true
        content = c
        // The guest operation managers live behind the GuestOperationsManager object.
        if let gom = c.guestOperationsManager {
            let props = try await retrieveProperties(of: [gom], paths: ["fileManager", "processManager"])
            if let first = props.first {
                c.fileManager = first.ref("fileManager")
                guestProcessManager = first.ref("processManager")
            }
        }
        content = c
        return c
    }

    private var guestProcessManager: MoRef?

    public func logout() async {
        guard isLoggedIn, let sm = content?.sessionManager else { return }
        isLoggedIn = false
        _ = try? await transport.call("Logout", this: sm)
    }

    /// Calls a method, logging in again once if the session has expired.
    @discardableResult
    public func call(_ method: String, this: MoRef, _ arguments: [XMLOut.Element] = []) async throws -> XMLNode {
        if !isLoggedIn { try await login() }
        do {
            return try await transport.call(method, this: this, arguments)
        } catch VimError.fault(let type, _) where type == "NotAuthenticated" {
            isLoggedIn = false
            try await login()
            return try await transport.call(method, this: this, arguments)
        }
    }

    // MARK: - Property collector

    /// One object and the properties that came back for it.
    public struct ObjectContent: Sendable {
        public var obj: MoRef
        public var props: [String: XMLNode]
        public var missing: [String]

        public func string(_ path: String) -> String? { props[path]?.trimmedText }
        public func int(_ path: String) -> Int? { string(path).flatMap { Int($0) } }
        public func int64(_ path: String) -> Int64? { string(path).flatMap { Int64($0) } }
        public func bool(_ path: String) -> Bool? { string(path).map { $0 == "true" } }
        public func date(_ path: String) -> Date? { string(path).flatMap(XMLNode.parseDate) }
        public func ref(_ path: String) -> MoRef? { MoRef(node: props[path]) }
    }

    /// The service content, logging in first when nothing has been called yet (the app's
    /// callers start with `listVMs()` or a guest operation, never with an explicit `login()`).
    func requireContent() async throws -> ServiceContent {
        if let content, isLoggedIn { return content }
        return try await login()
    }

    /// Properties of specific objects, all of one type.
    public func retrieveProperties(of objects: [MoRef], paths: [String]) async throws -> [ObjectContent] {
        guard let type = objects.first?.type else { return [] }
        let pc = try await requireContent().propertyCollector
        let propSet = XMLOut.Element("propSet", children: [.text("type", type)] + paths.map { .text("pathSet", $0) })
        let objectSets = objects.map { XMLOut.Element("objectSet", children: [.ref("obj", $0), .bool("skip", false)]) }
        let spec = XMLOut.Element("specSet", children: [propSet] + objectSets)
        return try await retrieve(pc: pc, spec: spec)
    }

    /// Properties of every object of a type under the root folder (through a container view).
    public func retrieveAll(type: String, paths: [String]) async throws -> [ObjectContent] {
        let c = try await requireContent()
        let view = try await call("CreateContainerView", this: c.viewManager, [
            .ref("container", c.rootFolder), .text("type", type), .bool("recursive", true),
        ])
        guard let viewRef = MoRef(node: view["returnval"]) else { throw VimError.malformedResponse("ContainerView") }
        defer { Task { _ = try? await transport.call("DestroyView", this: viewRef) } }
        let propSet = XMLOut.Element("propSet", children: [.text("type", type)] + paths.map { .text("pathSet", $0) })
        let traversal = XMLOut.Element.typed("selectSet", "TraversalSpec", [
            .text("name", "view"), .text("type", "ContainerView"), .text("path", "view"), .bool("skip", false),
        ])
        let objectSet = XMLOut.Element("objectSet", children: [.ref("obj", viewRef), .bool("skip", true), traversal])
        let spec = XMLOut.Element("specSet", children: [propSet, objectSet])
        return try await retrieve(pc: c.propertyCollector, spec: spec)
    }

    private func retrieve(pc: MoRef, spec: XMLOut.Element) async throws -> [ObjectContent] {
        var out: [ObjectContent] = []
        var response = try await call("RetrievePropertiesEx", this: pc, [spec, XMLOut.Element("options")])
        while true {
            guard let rv = response["returnval"] else { break }
            for o in rv.all("objects") {
                guard let obj = MoRef(node: o["obj"]) else { continue }
                var props: [String: XMLNode] = [:]
                for p in o.all("propSet") {
                    if let name = p.string("name"), let val = p["val"] { props[name] = val }
                }
                let missing = o.all("missingSet").compactMap { $0.string("path") }
                out.append(ObjectContent(obj: obj, props: props, missing: missing))
            }
            guard let token = rv.string("token") else { break }
            response = try await call("ContinueRetrievePropertiesEx", this: pc, [.text("token", token)])
        }
        return out
    }

    // MARK: - Tasks

    /// Waits for a task, polling its info; throws `taskFailed` with the fault message.
    public func waitForTask(_ task: MoRef, progress: (@Sendable (Int) -> Void)? = nil) async throws {
        var delay: UInt64 = 300_000_000
        while true {
            let infos = try await retrieveProperties(of: [task], paths: ["info.state", "info.error", "info.progress"])
            guard let info = infos.first else { throw VimError.malformedResponse("TaskInfo") }
            if let p = info.int("info.progress") { progress?(p) }
            switch info.string("info.state") {
            case "success": return
            case "error":
                let msg = info.props["info.error"]?.string("localizedMessage") ?? "The task failed"
                throw VimError.taskFailed(msg)
            default:
                try await Task.sleep(nanoseconds: delay)
                delay = min(delay * 2, 1_500_000_000)
            }
        }
    }

    /// Runs a `_Task` method and waits for it.
    public func runTask(_ method: String, this: MoRef, _ arguments: [XMLOut.Element] = []) async throws {
        let r = try await call(method, this: this, arguments)
        guard let task = MoRef(node: r["returnval"]) else { throw VimError.malformedResponse("Task") }
        try await waitForTask(task)
    }

    var processManager: MoRef? { guestProcessManager }
}
