import Foundation

/// A vim25 managed object reference: type and value (`VirtualMachine` / `105`).
public struct MoRef: Hashable, Sendable, Codable, CustomStringConvertible {
    public var type: String
    public var value: String

    public init(type: String, value: String) {
        self.type = type
        self.value = value
    }

    /// Reads `<x type="T">v</x>`.
    init?(node: XMLNode?) {
        guard let node, let type = node.attributes["type"] else { return nil }
        self.init(type: type, value: node.trimmedText)
    }

    public var description: String { "\(type):\(value)" }

    public static let serviceInstance = MoRef(type: "ServiceInstance", value: "ServiceInstance")
}

/// What went wrong talking to a host. `fault` carries the vim25 fault type (`InvalidLogin`,
/// `NotAuthenticated`, `GuestOperationsUnavailable`, …) and the server's message.
public enum VimError: Error, Sendable, LocalizedError {
    case transport(String)
    case httpStatus(Int)
    case malformedResponse(String)
    case fault(type: String, message: String)
    case certificateChanged(expected: String, actual: String)
    case taskFailed(String)
    case notConnected
    case guestOperation(String)

    public var errorDescription: String? {
        switch self {
        case .transport(let s): "Couldn't reach the host: \(s)"
        case .httpStatus(let c): "The host answered HTTP \(c)"
        case .malformedResponse(let s): "The host sent something unexpected: \(s)"
        case .fault(let type, let message):
            switch type {
            case "InvalidLogin": "Wrong user name or password"
            case "NotAuthenticated": "The session expired"
            case "InvalidGuestLogin": "The guest rejected the user name or password"
            case "GuestOperationsUnavailable": "VMware Tools isn't running in the guest"
            case "InvalidPowerState": "The VM is in the wrong power state for that"
            case "InvalidState": "The VM isn't in a state that allows this (is it powered on?)"
            case "ToolsUnavailable": "VMware Tools isn't running in the guest"
            case "FileFault", "FileNotFound": message.isEmpty ? "The file wasn't found" : message
            case "RestrictedVersion": "This ESXi licence doesn't allow that operation"
            case "TaskInProgress": "Another task is still running on this VM"
            default: message.isEmpty ? type : message
            }
        case .certificateChanged(let expected, let actual):
            "The host's certificate changed (expected \(expected), got \(actual))"
        case .taskFailed(let s): s
        case .notConnected: "Not connected"
        case .guestOperation(let s): s
        }
    }

    public var faultType: String? {
        if case .fault(let type, _) = self { return type }
        return nil
    }
}
