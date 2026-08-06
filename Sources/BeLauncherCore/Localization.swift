import Foundation

/// Two languages, and the rule that keeps them from leaking into each other.
///
/// The product sells in the United States, so English is the base and Spanish is the translation —
/// not the other way round. That ordering is not decoration: the base language is the one every
/// string is written in at the call site, the one a missing translation falls back to, and the one
/// a reviewer reads when judging whether a sentence has a voice.
///
/// **Interface language and corpus language are different things and must never be tied.** Someone
/// in Miami runs the interface in English and has a memory full of Spanish messages from their
/// family. Binding the tokenizer, the stopwords or the model prompt to whatever the menu bar is
/// showing would quietly wreck half their recall. Anything that reads the user's own material is
/// bilingual all the time; only what the app says to the user follows this setting.
public enum Language: String, Sendable, CaseIterable, Codable {
    case english = "en"
    case spanish = "es"

    /// The name of the language written in that language, which is what a language picker shows.
    /// Showing "Spanish" to a Spanish speaker is a small tell that the product was not made for
    /// them.
    public var endonym: String {
        switch self {
        case .english: "English"
        case .spanish: "Español"
        }
    }

    /// For date and number formatting. `en_US` rather than `en_GB` because that is the market.
    public var localeIdentifier: String {
        switch self {
        case .english: "en_US"
        case .spanish: "es_ES"
        }
    }

    public var locale: Locale { Locale(identifier: localeIdentifier) }

    /// Picks a language from what the system reports, e.g. `["es-419", "en-US"]`.
    ///
    /// Only the leading subtag is compared: macOS hands back `es-419`, `es-MX`, `en-GB` and a dozen
    /// other shapes, and matching the whole identifier means a Mexican Mac gets English.
    public static func best(matching identifiers: [String]) -> Language {
        for identifier in identifiers {
            let base = identifier.split(whereSeparator: { $0 == "-" || $0 == "_" }).first
                .map(String.init)?.lowercased()
            if let base, let match = Language(rawValue: base) { return match }
        }
        return .english
    }

    /// What the app should run in: an explicit choice wins, otherwise the system's preference,
    /// otherwise English.
    ///
    /// Kept as a pure function so the decision can be tested without a Mac's language list. The
    /// stored value is whatever was persisted, which may be empty on first run or garbage after a
    /// downgrade — both have to resolve to something rather than trap.
    public static func resolve(stored: String?, systemPreferred: [String]) -> Language {
        if let stored, let explicit = Language(rawValue: stored) { return explicit }
        return best(matching: systemPreferred)
    }
}

/// The catalog lookup, and the one global the app reads on every label.
public enum Loc {

    /// The language the interface is drawn in. Set once at launch and again when the user picks
    /// another one in Settings.
    public static var language: Language {
        get { storage.value }
        set { storage.value = newValue }
    }

    /// Renders a base-language string in a given language, substituting arguments.
    ///
    /// Public and explicit about the language because that is what makes the catalog testable: a
    /// test asserts what a Spanish user reads without touching a global and without ordering
    /// problems when tests run in parallel.
    public static func render(_ base: String, in language: Language,
                              _ arguments: [String] = []) -> String {
        let template = language == .english ? base : (SpanishStrings.table[base] ?? base)
        return substitute(template, arguments)
    }

    /// Whether a base string has a Spanish counterpart. Used by the completeness test, and by
    /// nothing else: at runtime a missing translation silently falls back to English, which is the
    /// right behaviour for a user and the wrong one for a build.
    public static func hasTranslation(_ base: String) -> Bool {
        SpanishStrings.table[base] != nil
    }

    /// Fills `%1$@`, `%2$@`… and bare `%@` placeholders.
    ///
    /// Hand-rolled instead of `String(format:)` on purpose. `String(format:)` takes `CVarArg`, so a
    /// mismatch between the placeholder and the argument type is a crash at runtime rather than an
    /// error at compile time — and a translated string is exactly the kind of thing that gets
    /// edited by someone who is not looking at the call site. Here every argument is already a
    /// String, so the worst case is a placeholder that does not get filled.
    ///
    /// Numbered placeholders exist because word order changes: "3 items in Inbox" is
    /// "Inbox: 3 elementos" and the translation has to be able to move them.
    static func substitute(_ template: String, _ arguments: [String]) -> String {
        guard !arguments.isEmpty else { return template }
        var result = ""
        let characters = Array(template)
        var index = 0
        var nextPositional = 0

        while index < characters.count {
            guard characters[index] == "%", index + 1 < characters.count else {
                result.append(characters[index])
                index += 1
                continue
            }
            if characters[index + 1] == "@" {
                if nextPositional < arguments.count { result += arguments[nextPositional] }
                nextPositional += 1
                index += 2
                continue
            }
            if characters[index + 1] == "%" {
                result.append("%")
                index += 2
                continue
            }
            // "%12$@": read the digits, then require "$@" behind them.
            var cursor = index + 1
            var digits = ""
            while cursor < characters.count, characters[cursor].isNumber {
                digits.append(characters[cursor])
                cursor += 1
            }
            if !digits.isEmpty, cursor + 1 < characters.count,
               characters[cursor] == "$", characters[cursor + 1] == "@",
               let position = Int(digits), position >= 1, position <= arguments.count {
                result += arguments[position - 1]
                index = cursor + 2
                continue
            }
            result.append(characters[index])
            index += 1
        }
        return result
    }

    // A lock rather than an actor: this is read on the main thread by every label being drawn and
    // written twice in the life of the process. An actor would make every label an await.
    private static let storage = LanguageStorage()

    private final class LanguageStorage: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Language = .english

        var value: Language {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }
}

/// The call site. Short on purpose: it appears hundreds of times and a longer name would push
/// every string in the app onto its own line.
///
/// The English text *is* the key. There is no separate identifier file to keep in sync, the source
/// reads as the language the product ships in, and an untranslated string degrades to English
/// rather than to `settings.brain.header.title`. The cost is that editing the English breaks the
/// Spanish lookup — which is why a test walks the source and fails on any call site whose text is
/// missing from the catalog.
public func L(_ english: String, _ arguments: String...) -> String {
    Loc.render(english, in: Loc.language, arguments)
}

/// Same, in a stated language. For anything rendered outside the interface — an exported file, a
/// message written for a specific reader — where the menu bar's language is not the right answer.
public func L(_ english: String, in language: Language, _ arguments: String...) -> String {
    Loc.render(english, in: language, arguments)
}
