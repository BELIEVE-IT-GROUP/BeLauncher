import Foundation
import NaturalLanguage

/// The words the app listens for, and the words it throws away.
///
/// These used to live inline in five different files, all of them Spanish, which meant the feature
/// existed only for someone typing Spanish. Typing "save workspace" reached nothing; typing
/// "guardar espacio" reached everything. That is not a translation problem, it is a broken feature
/// with a language-shaped cause, and it is why these tables sit in one place now.
///
/// **Every table here is bilingual all the time, regardless of the interface language.** A person
/// whose Mac is in English still types "resumen" when they are thinking in Spanish, and the cost of
/// listening for both is a handful of extra string comparisons. Tying recognition to the interface
/// setting would mean a user who switches the menu bar to English loses commands that worked
/// yesterday — a silent regression they would blame on the app being unreliable, not on a setting.
public enum Phrases {

    /// Comparison form: no accents, no case, no surrounding space. Every table below is already
    /// written this way, so a lookup never has to fold twice.
    public static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Matches the longest prefix in `prefixes` and returns what came after it.
    ///
    /// Longest wins, which matters more than it looks: "que decidimos sobre X" also starts with
    /// "que decidimos ", and taking the first match would leave "sobre X" as the topic.
    public static func after(anyOf prefixes: [String], in folded: String) -> String? {
        var best: (prefix: String, rest: String)?
        for prefix in prefixes where folded.hasPrefix(prefix) {
            if best == nil || prefix.count > best!.prefix.count {
                best = (prefix, String(folded.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespaces))
            }
        }
        guard let best, !best.rest.isEmpty else { return nil }
        return best.rest
    }

    /// Whether the text is one of these phrases, or opens with one.
    public static func matches(anyOf phrases: [String], in folded: String) -> Bool {
        phrases.contains { folded == $0 || folded.hasPrefix($0 + " ") || folded.hasPrefix($0) }
    }

    // MARK: - The brain

    public static let whatDidWeDecide = [
        "what did we decide about ", "what did we decide on ", "what did we decide ",
        "what was decided about ", "what's the decision on ", "whats the decision on ",
        "que decidimos sobre ", "que decidimos de ", "que decidimos ", "que se decidio sobre ",
    ]

    public static let prepare = [
        "prepare me for ", "prepare me ", "prep me for ", "brief me on ", "brief me ",
        "get me ready for ", "prepare for ", "prepare ",
        "preparame para ", "preparame ", "preparar reunion con ", "preparar reunion ",
        "prepara ", "ponme al dia sobre ",
    ]

    public static let remember = [
        "remember ", "remember that ", "note that ", "save this ",
        "recordar ", "recuerda ", "recuerda que ", "apunta ",
    ]

    public static let pulse = [
        "pulse", "what am i missing", "what's at risk", "whats at risk", "risks",
        "pulso", "que se me escapa", "que esta en riesgo", "riesgos",
    ]

    public static let naturalBrainQuestion = [
        "ask brain", "ask my brain", "ask bebrain", "ask the brain",
        "pregunta al brain", "preguntale al brain", "preguntale a mi brain",
        "pregunta al cerebro", "preguntale al cerebro", "preguntale a mi cerebro",
        "brain pregunta", "cerebro pregunta",
    ]

    // MARK: - The work graph

    public static let promisedTo = [
        "what did we promise ", "what did we promise to ", "what do we owe ",
        "what did i promise ",
        "que prometimos a ", "que le prometimos a ", "que debemos a ", "que prometi a ",
    ]

    public static let lastAbout = [
        "open the latest on ", "latest on ", "last thing on ", "most recent on ",
        "abre lo ultimo de ", "abre lo ultimo relacionado con ", "lo ultimo de ", "ultimo de ",
    ]

    public static let resumeBefore = [
        "resume where i left", "pick up where i left", "what was i doing", "back to what i was doing",
        "retoma lo que estaba haciendo", "retomar donde lo deje", "en que estaba",
    ]

    public static let about = [
        "who is ", "what do we know about ", "everything about ", "all about ",
        "quien es ", "que sabemos de ", "todo sobre ",
    ]

    // MARK: - Workspaces

    public static let saveWorkspace = [
        "save workspace ", "save layout ", "save windows ", "save this layout ",
        "guardar espacio ", "guardar layout ", "guardar ventanas ", "guardar disposicion ",
    ]

    public static let restoreWorkspace = [
        "workspace ", "layout ", "restore ", "restore workspace ",
        "espacio ", "restaurar ",
    ]

    public static let listWorkspaces = [
        "workspaces", "layouts", "espacios",
    ]

    // MARK: - Words that carry no meaning

    /// Stopwords for both languages at once, always.
    ///
    /// This one is not an interface concern at all: it runs over the user's own text when deciding
    /// whether two memories are about the same thing. The list was Spanish-only, so an English
    /// corpus compared "the price of the plan" against "the plan for the price" and found them
    /// unrelated — every function word counted as a real word and diluted the overlap. Merging both
    /// lists costs nothing and works on a bilingual corpus, which is what most real ones are.
    ///
    /// Deliberately short. A long stopword list starts deleting words that matter: "no" is a
    /// stopword and "no" is also the difference between two opposite decisions.
    public static let stopwords: Set<String> = [
        // Spanish
        "el", "la", "los", "las", "de", "del", "que", "y", "a", "en", "para", "con", "un", "una",
        "no", "se", "es", "por", "al", "lo", "su", "sus", "como", "mas", "pero", "este", "esta",
        // English
        "the", "of", "to", "and", "in", "for", "with", "on", "at", "by", "is", "are", "was",
        "were", "be", "this", "that", "it", "as", "from", "or", "an", "but", "not", "we", "our",
    ]

    /// The words of a text that are worth comparing: long enough to mean something, not on the
    /// stopword list.
    public static func significantWords(_ text: String) -> [String] {
        fold(text)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count > 2 && !stopwords.contains($0) }
    }

    // MARK: - The language of the material

    /// What to assume when the language of a piece of text cannot be detected.
    ///
    /// Detection runs per text, which is what makes a bilingual corpus work without anyone
    /// configuring anything: the Spanish note is tokenized as Spanish and the English one as
    /// English, in the same index, on the same day. Only a fragment too short to identify falls
    /// through to this, and English is the floor because it is the market — not because the corpus
    /// is assumed to be English.
    ///
    /// It is settable, and it is deliberately *not* wired to `Loc.language`. Someone reading the
    /// interface in English whose notes are Spanish should be able to say so without the app
    /// changing what language its own menus are in.
    public static var corpusFallback: NLLanguage {
        get { fallbackStorage.value }
        set { fallbackStorage.value = newValue }
    }

    /// The detected language of a text, or the fallback.
    public static func language(of text: String) -> NLLanguage {
        NLLanguageRecognizer.dominantLanguage(for: text) ?? corpusFallback
    }

    private static let fallbackStorage = FallbackStorage()

    private final class FallbackStorage: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: NLLanguage = .english

        var value: NLLanguage {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }
}
