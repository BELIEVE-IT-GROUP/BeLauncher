import Foundation

/// The stable contract behind every BeLauncher action, native or model-backed.
///
/// The identifier here is the product's promise: it never changes and it is never a localized
/// title. `ResultAction` stays the view's model and is projected from this, so the launcher keeps
/// one source of truth for identity, risk and confirmation instead of the four catalogues that
/// grew separately (`ResultAction`, `SystemCommand`, `FlowStep`, `LauncherModel.Action`).
public struct BELActionDefinition: Codable, Sendable, Identifiable, Equatable {

    public enum Kind: String, Codable, Sendable {
        case native
        case ai
        case agentic
    }

    /// How much a person stands to lose if the action runs when they did not mean it.
    public enum Risk: String, Codable, Sendable, Comparable, CaseIterable {
        /// Read-only or a pure transformation.
        case r0
        /// Creates or changes local data. Runs, and offers undo where the adapter can.
        case r1
        /// External side effect, or a broad change across many files. Preview and confirm.
        case r2
        /// Destructive, irreversible or credential-sensitive. Always confirmed, never inferred.
        case r3

        public static func < (lhs: Risk, rhs: Risk) -> Bool {
            allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
        }
    }

    /// A permission or resource the action cannot run without.
    ///
    /// Distinct from the TCC states in `CapabilityHealth`: this says what an action *needs*, the
    /// health object says what the app currently *has*. `PermissionGate` compares the two.
    public enum Capability: String, Codable, Sendable, CaseIterable {
        case files
        case fullDiskAccess
        case clipboard
        case calendar
        case reminders
        case contacts
        case photos
        case mail
        case messages
        case screenRecording
        case microphone
        case accessibility
        case automation
        case location
        case shortcuts
        case network
        case localModel
        case cloudModel
        case web
    }

    /// How much of the person's Be Brain the action is allowed to see.
    public enum BrainContextLevel: String, Codable, Sendable {
        /// Nothing beyond the request itself.
        case b0
        /// Language, formatting and general response preferences.
        case b1
        /// B1 plus the current project or workspace and relevant recent context.
        case b2
        /// B2 plus long-term memories, people, goals and prior decisions.
        case b3
    }

    /// Which class of engine may serve the action. The router picks the provider; the definition
    /// only states the policy, so no action ever names a model.
    public enum RoutePolicy: String, Codable, Sendable {
        /// Deterministic. Calling a model here would be a bug.
        case deterministic
        /// Never leaves the Mac, even if that means refusing.
        case localOnly
        case localFirst
        case hybrid
        case cloudPreferred
        /// Needs information the model cannot have. Must reach a fresh source.
        case cloudWeb
        case visionRoute
    }

    public enum Freshness: String, Codable, Sendable {
        case notRequired
        /// A stale local model may not answer this on its own.
        case required
    }

    /// The execution path, in the order section 4.1 of the spec requires them to be tried.
    public enum Adapter: String, Codable, Sendable {
        case publicAPI
        case ownAppIntent
        case shortcut
        case urlScheme
        case appleScript
        case allowlistedShell
        /// Served by the model router rather than a system API.
        case model
        case none
    }

    /// Whether this action actually runs today.
    ///
    /// This exists so the catalogue cannot lie. An action is `implemented` only when a handler is
    /// registered and a test invokes it by identifier; everything else is honest about being a
    /// declared identifier with no working path yet.
    public enum Availability: String, Codable, Sendable {
        /// A handler exists and is covered by a test.
        case implemented
        /// Reachable only through a `BEL • …` Shortcut the person must have installed.
        case shortcutFallback
        /// Declared for the contract, with no working path on the target OS yet.
        case unavailable
    }

    public struct ArgumentSpec: Codable, Sendable, Equatable {
        public enum ValueType: String, Codable, Sendable {
            case text, path, url, integer, decimal, boolean, date, duration, percentage
            case fileList, imageRef, audioRef, contactRef, enumeration
        }

        public let name: String
        public let type: ValueType
        public let isRequired: Bool

        public init(_ name: String, _ type: ValueType, required: Bool = true) {
            self.name = name
            self.type = type
            self.isRequired = required
        }
    }

    public let id: String
    public let version: Int
    public let kind: Kind
    /// Looked up with `L()` at the view layer. Never used as identity.
    public let titleKey: String
    public let aliases: [String]
    public let arguments: [ArgumentSpec]
    public let output: ArgumentSpec.ValueType?
    public let requiredCapabilities: Set<Capability>
    public let brainContextLevel: BrainContextLevel
    public let risk: Risk
    public let routePolicy: RoutePolicy
    public let freshness: Freshness
    public let adapter: Adapter
    public let availability: Availability

    public init(id: String,
                version: Int = 1,
                kind: Kind,
                titleKey: String,
                aliases: [String] = [],
                arguments: [ArgumentSpec] = [],
                output: ArgumentSpec.ValueType? = nil,
                requiredCapabilities: Set<Capability> = [],
                brainContextLevel: BrainContextLevel = .b0,
                risk: Risk,
                routePolicy: RoutePolicy = .deterministic,
                freshness: Freshness = .notRequired,
                adapter: Adapter,
                availability: Availability) {
        self.id = id
        self.version = version
        self.kind = kind
        self.titleKey = titleKey
        self.aliases = aliases
        self.arguments = arguments
        self.output = output
        self.requiredCapabilities = requiredCapabilities
        self.brainContextLevel = brainContextLevel
        self.risk = risk
        self.routePolicy = routePolicy
        self.freshness = freshness
        self.adapter = adapter
        self.availability = availability
    }

    /// True when the action must be confirmed before it runs, whatever the caller believes.
    public var alwaysConfirms: Bool { risk >= .r2 }

    /// True when sending this action's context to a provider off the Mac is forbidden outright.
    public var isLocalOnly: Bool { routePolicy == .localOnly }
}
