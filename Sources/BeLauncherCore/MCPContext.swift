import Foundation

/// Everything a tool call can reach.
///
/// Bundled into one value rather than passed as five arguments because the set grew — the tools
/// used to see only the vault, which is why every one of them answered "no sé nada" while a
/// hundred and fifty indexed passages sat next to them untouched. A context makes adding a source
/// a change in one place instead of a change at every call site, and makes it obvious in a
/// signature what a tool is allowed to see.
///
/// Main-actor bound because `Store`, `Vault` and `BrainSearch` all are: the whole app is one
/// process with one database, and a lock here would be ceremony with nothing to protect.
@MainActor
public struct MCPContext {
    public let vault: Vault
    public let store: Store
    /// Absent when no index has been built yet, which is a state the tools have to answer for
    /// honestly rather than crash on.
    public let brain: BrainSearch?
    public let events: [CalendarEvent]

    public init(vault: Vault, store: Store, brain: BrainSearch? = nil,
                events: [CalendarEvent] = []) {
        self.vault = vault
        self.store = store
        self.brain = brain
        self.events = events
    }
}
