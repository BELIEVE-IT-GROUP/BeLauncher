import Foundation

/// The live state of a capability at the moment an action is about to run.
public enum BELCapabilityStatus: String, Codable, Sendable, Equatable {
    case granted
    case needsPermission
    case denied
    case unavailable
}

public struct BELCapabilitySnapshot: Sendable, Equatable {
    private let states: [BELActionDefinition.Capability: BELCapabilityStatus]

    public init(states: [BELActionDefinition.Capability: BELCapabilityStatus] = [:]) {
        self.states = states
    }

    public static let allGranted = BELCapabilitySnapshot(
        states: Dictionary(uniqueKeysWithValues:
            BELActionDefinition.Capability.allCases.map { ($0, .granted) }))

    public func status(for capability: BELActionDefinition.Capability) -> BELCapabilityStatus {
        states[capability] ?? .unavailable
    }
}

/// The only permission/risk decision an action runner is allowed to consume.
public enum BELActionGate {
    public enum Blocker: Sendable, Equatable {
        case unavailable
        case missingCapability(BELActionDefinition.Capability)
        case deniedCapability(BELActionDefinition.Capability)
    }

    public enum Decision: Sendable, Equatable {
        case allowed
        case requiresConfirmation
        case blocked(Blocker)
    }

    public static func decide(_ definition: BELActionDefinition,
                              capabilities: BELCapabilitySnapshot,
                              confirmed: Bool = false) -> Decision {
        guard definition.availability != .unavailable else { return .blocked(.unavailable) }

        for capability in definition.requiredCapabilities.sorted(by: { $0.rawValue < $1.rawValue }) {
            switch capabilities.status(for: capability) {
            case .granted: continue
            case .denied: return .blocked(.deniedCapability(capability))
            case .needsPermission, .unavailable:
                return .blocked(.missingCapability(capability))
            }
        }

        if definition.alwaysConfirms && !confirmed { return .requiresConfirmation }
        return .allowed
    }
}

public struct BELActionResult: Codable, Sendable, Equatable {
    public let text: String
    public let changed: [String]
    public let receipt: String

    public init(text: String, changed: [String] = [], receipt: String = "") {
        self.text = text
        self.changed = changed
        self.receipt = receipt
    }
}

/// An adapter owns execution; it never owns the permission or confirmation policy.
public protocol BELActionHandler: Sendable {
    var actionID: String { get }
    func perform(input: Data) async throws -> BELActionResult
}

public enum BELActionExecutionError: Error, Sendable, Equatable {
    case blocked(BELActionGate.Blocker)
    case confirmationRequired
    case handlerDoesNotMatch(expected: String, received: String)
}

/// Runs a handler only after the central gate has approved the definition.
public enum BELActionExecutor {
    public static func execute(_ definition: BELActionDefinition,
                               input: Data = Data(),
                               capabilities: BELCapabilitySnapshot,
                               confirmed: Bool = false,
                               handler: any BELActionHandler) async throws -> BELActionResult {
        guard handler.actionID == definition.id else {
            throw BELActionExecutionError.handlerDoesNotMatch(expected: definition.id,
                                                               received: handler.actionID)
        }
        switch BELActionGate.decide(definition, capabilities: capabilities, confirmed: confirmed) {
        case .allowed:
            return try await handler.perform(input: input)
        case .requiresConfirmation:
            throw BELActionExecutionError.confirmationRequired
        case .blocked(let blocker):
            throw BELActionExecutionError.blocked(blocker)
        }
    }
}
