import Foundation

/// The same thing, called four different ways.
///
/// A project shows up as `/Users/mac/Developer/waw-trips`, as a browser tab reading "WAW Trips ·
/// Panel", as a file called `waw-trips-propuesta.pdf` and as the words "lo de WAW" in a note. If
/// those are four nodes then the graph is decorative: every question about the project reaches a
/// quarter of what is known about it, and the missing three quarters are invisible — nothing tells
/// you an answer was incomplete.
///
/// So entities are canonical, with aliases underneath. The hard part is not merging; it is
/// merging *wrongly*. A bad merge silently contaminates every future answer and cannot be seen
/// from outside, which is why nothing here merges on a hunch: strong evidence merges, weak
/// evidence proposes, and a rejection is remembered forever.
public struct Entity: Sendable, Equatable, Identifiable, Codable {

    public enum Kind: String, Sendable, Codable, CaseIterable {
        case person
        case project
        case company
        case topic

        public var label: String {
            switch self {
            case .person: "Persona"
            case .project: "Proyecto"
            case .company: "Empresa"
            case .topic: "Asunto"
            }
        }
    }

    public let id: String
    public let kind: Kind
    /// The name a person would use out loud. Aliases are everything else it answers to.
    public var canonical: String
    public var aliases: Set<String>
    /// How many times this has been seen. Ranking, never truth.
    public var weight: Int

    public init(id: String? = nil, kind: Kind, canonical: String,
                aliases: Set<String> = [], weight: Int = 1) {
        self.kind = kind
        self.canonical = canonical
        self.aliases = aliases
        self.weight = weight
        self.id = id ?? "entity:\(kind.rawValue):" + Identity.fold(canonical)
    }

    /// Everything this answers to, folded for comparison.
    public var forms: Set<String> {
        Set(([canonical] + aliases).map(Identity.fold))
    }

    public func answers(to name: String) -> Bool {
        forms.contains(Identity.fold(name))
    }
}

/// A merge that has not happened yet.
public struct MergeProposal: Sendable, Equatable, Identifiable {

    public enum Reason: String, Sendable, Equatable {
        /// The two names are the same once case, accents and separators are ignored.
        case sameName
        /// One is a path or a URL whose meaningful part is the other's name.
        case pathMatch
        /// Two addresses at the same company domain.
        case sameDomain
        /// They keep turning up in the same episodes.
        case seenTogether

        public var explanation: String {
            switch self {
            case .sameName: L("they are spelled the same but for case, accents or hyphens")
            case .pathMatch: L("one is the folder or the address of the other")
            case .sameDomain: L("they are on the same domain")
            case .seenTogether: L("they turn up together again and again")
            }
        }

        /// Whether this alone is enough to merge without asking.
        ///
        /// Only the first two. Sharing a domain makes two people colleagues, not the same person,
        /// and things that appear together are usually related rather than identical — merging on
        /// that would fold a project into the person who works on it and lose both.
        public var isConclusive: Bool { self == .sameName || self == .pathMatch }
    }

    public var id: String { [left, right].sorted().joined(separator: "≡") }
    public let left: String
    public let right: String
    public let reason: Reason

    public init(left: String, right: String, reason: Reason) {
        self.left = left
        self.right = right
        self.reason = reason
    }

    public var question: String {
        L("Are “%1$@” and “%2$@” the same thing? I ask because %3$@.", left, right, reason.explanation)
    }
}

public enum Identity {

    /// Names that are never an entity.
    ///
    /// Every Mac has a `src`, a `docs` and a `Desktop`, and a project called `src` would swallow
    /// half the graph: it appears everywhere, so it connects to everything, so it means nothing.
    /// Stored already folded. A test caught "node_modules" sitting in this list and never
    /// matching anything, because `fold` turns underscores into spaces before comparing.
    public static let generic: Set<String> = [
        "src", "lib", "bin", "tmp", "temp", "test", "tests", "docs", "doc", "build", "dist",
        "node modules", "assets", "images", "img", "public", "static", "config", "scripts",
        "desktop", "downloads", "documents", "library", "applications", "users", "home",
        "escritorio", "descargas", "documentos", "aplicaciones", "proyectos", "projects",
        "untitled", L("no title"), L("new folder"), "new folder",
    ]

    /// Sites that are places you pass through, never things you work on.
    ///
    /// A graph of somebody's month that lists `google.com`, `instagram.com` and `youtube.com` as
    /// projects is a browser history with a nicer font. It was measured on a real Mac: the first
    /// graph anyone saw was twenty three dots and most of them were these. They are still visited,
    /// still captured and still searchable; they just do not get to be entities, because an entity
    /// is something work is *about*.
    public static let passingThrough: Set<String> = [
        "google.com", "google.es", "bing.com", "duckduckgo.com", "youtube.com", "instagram.com",
        "facebook.com", "x.com", "twitter.com", "threads.com", "tiktok.com", "reddit.com",
        "linkedin.com", "whatsapp.com", "web.whatsapp.com", "mail.google.com", "gmail.com",
        "calendar.google.com", "drive.google.com", "amazon.com", "amazon.es", "netflix.com",
        "chatgpt.com", "claude.ai", "spotify.com", "wikipedia.org", "stackoverflow.com",
        "localhost", "127.0.0.1",
    ]

    /// Whether a host is somewhere you pass through rather than something you work on.
    public static func isPassingThrough(_ host: String) -> Bool {
        let clean = host.lowercased()
            .replacingOccurrences(of: "www.", with: "")
            .trimmingCharacters(in: .whitespaces)
        if passingThrough.contains(clean) { return true }
        // A subdomain of one of these is the same place: `m.youtube.com` is still YouTube. But a
        // subdomain of your own company is not, which is why the match is on the tail and the list
        // holds no bare company names.
        return passingThrough.contains { clean.hasSuffix("." + $0) }
    }

    /// Free mail providers, which say nothing about where somebody works.
    public static let freeMail: Set<String> = [
        "gmail.com", "googlemail.com", "hotmail.com", "outlook.com", "live.com", "yahoo.com",
        "icloud.com", "me.com", "mac.com", "proton.me", "protonmail.com", "aol.com",
    ]

    /// One comparable form: no accents, no case, separators collapsed to spaces.
    ///
    /// "WAW Trips", "waw-trips" and "waw_trips" have to compare equal, because they are the same
    /// project written by three different tools.
    public static func fold(_ text: String) -> String {
        let lowered = text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let spaced = lowered.map { character -> Character in
            if character == "-" || character == "_" || character == "." || character == "/" { return " " }
            return character
        }
        return String(spaced)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    public static func isGeneric(_ name: String) -> Bool {
        let folded = fold(name)
        return folded.isEmpty || folded.count < 3 || generic.contains(folded)
    }

    /// The part of a path worth naming: the last component that is not generic.
    ///
    /// `/Users/mac/Developer/waw-trips/src/index.ts` is about `waw-trips`, not about `src` and not
    /// about `index`. Walking up from the file until something meaningful appears is what turns a
    /// path into a project instead of into noise.
    public static func project(fromPath path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        // The filename is dropped: a file is not a project, and its own entity exists separately.
        for component in parts.dropLast().reversed() where !isGeneric(component) {
            // Home directories look like projects and are not.
            if component == NSUserName() { return nil }
            return component
        }
        return nil
    }

    public static func company(fromEmail address: String) -> String? {
        guard let at = address.firstIndex(of: "@") else { return nil }
        let domain = String(address[address.index(after: at)...]).lowercased()
        guard !freeMail.contains(domain), domain.contains(".") else { return nil }
        return domain.split(separator: ".").dropLast().joined(separator: ".")
    }

    // MARK: - Deciding whether two are one

    /// What links two entities, if anything.
    ///
    /// Returns the strongest reason only. Reporting three weak reasons as if they stacked is how a
    /// merge based on nothing ends up looking well justified.
    public static func link(_ a: Entity, _ b: Entity, together: Int = 0) -> MergeProposal.Reason? {
        // Different kinds are never the same thing. A person and the project named after them are
        // the classic bad merge, and the one that destroys the most: it makes every question about
        // either return a mix of both.
        guard a.kind == b.kind, a.id != b.id else { return nil }

        if !a.forms.isDisjoint(with: b.forms) { return .sameName }

        for form in a.forms where b.forms.contains(where: { isPathwise(form, $0) }) {
            return .pathMatch
        }
        if a.kind == .company, let left = a.canonical.split(separator: "@").last,
           let right = b.canonical.split(separator: "@").last, left == right {
            return .sameDomain
        }
        // Deliberately high. Two things that turn up together five times are related; the same
        // thing under two names turns up together every single time.
        if together >= 8 { return .seenTogether }
        return nil
    }

    /// Whether one form is the other wrapped in a path or an address.
    static func isPathwise(_ a: String, _ b: String) -> Bool {
        guard a != b else { return true }
        let (long, short) = a.count >= b.count ? (a, b) : (b, a)
        guard short.count >= 4 else { return false }
        // Word boundaries, not substring: "waw" inside "wawa" is a coincidence, "waw trips" as a
        // whole word inside a path is not.
        return long.split(separator: " ").contains(String.SubSequence(short))
            || long.hasSuffix(" " + short) || long.hasPrefix(short + " ")
    }

    /// What to do about two entities that might be one.
    public enum Verdict: Sendable, Equatable {
        case merge(MergeProposal.Reason)
        case ask(MergeProposal)
        case leaveAlone
    }

    /// The decision, with everything already rejected taken into account.
    ///
    /// A rejected merge is remembered forever on purpose. Asking twice about the same pair is how
    /// a correction stops feeling like teaching the system and starts feeling like arguing with
    /// it, and the whole value of letting somebody correct the graph is that the correction
    /// sticks.
    public static func decide(_ a: Entity, _ b: Entity, together: Int = 0,
                              rejected: Set<String> = []) -> Verdict {
        guard let reason = link(a, b, together: together) else { return .leaveAlone }
        let proposal = MergeProposal(left: a.canonical, right: b.canonical, reason: reason)
        if rejected.contains(proposal.id) { return .leaveAlone }
        return reason.isConclusive ? .merge(reason) : .ask(proposal)
    }

    /// Folds one entity into another, keeping every name it ever answered to.
    ///
    /// The surviving canonical is the one seen more often, because that is the name the person
    /// actually uses; the other becomes an alias rather than disappearing, so a search for the old
    /// name still lands.
    public static func merge(_ a: Entity, _ b: Entity) -> Entity {
        let (winner, loser) = a.weight >= b.weight ? (a, b) : (b, a)
        return Entity(
            id: winner.id, kind: winner.kind, canonical: winner.canonical,
            aliases: winner.aliases.union(loser.aliases).union([loser.canonical]),
            weight: a.weight + b.weight
        )
    }
}
