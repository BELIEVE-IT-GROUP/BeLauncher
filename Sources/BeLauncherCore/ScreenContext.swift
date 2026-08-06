import Foundation

/// What you are looking at, plus what you want done with it.
///
/// Until now the only input was typing, which means every task started with explaining context the
/// machine could already see: copy the error, switch window, paste, describe where it came from.
/// The point of this is to delete that entire ritual — you press one key with the thing on screen
/// and the app already knows what it is.
///
/// The parts that touch the system live in the app layer. Everything here is the decision-making:
/// what kind of thing is on screen, and therefore what is worth offering to do with it. Keeping it
/// separate means the interesting half is testable without a camera on the display.
public struct ScreenContext: Sendable, Equatable {

    /// What was captured, in order of preference: a real selection beats OCR of the whole screen.
    public enum Origin: String, Sendable, Equatable {
        /// Text the user had selected, read through Accessibility.
        case selection
        /// Text recognised from the screen image.
        case recognised
        /// A file the frontmost window is showing.
        case file
        case clipboard

        public var label: String {
            switch self {
            case .selection: L("what you have selected")
            case .recognised: L("what is on screen")
            case .file: L("the open file")
            case .clipboard: L("what you copied")
            }
        }
    }

    public let text: String
    public let origin: Origin
    /// The app it came from, which is half of what makes an offer sensible.
    public let application: String
    /// A file path, when the thing on screen is a file.
    public let path: String

    public init(text: String, origin: Origin, application: String = "", path: String = "") {
        self.text = text
        self.origin = origin
        self.application = application
        self.path = path
    }

    public var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && path.isEmpty
    }
}

/// Works out what is on screen and what is worth doing about it.
public enum ScreenReader {

    /// The kinds of thing worth recognising. A closed list, because an offer that is right 60% of
    /// the time is worse than three offers that are always sensible: people stop looking.
    public enum Subject: String, Sendable, Equatable, CaseIterable {
        case error
        case invoice
        case email
        case table
        case code
        case design
        case link
        case prose

        public var label: String {
            switch self {
            case .error: L("An error")
            case .invoice: L("An invoice")
            case .email: L("An email")
            case .table: L("A table")
            case .code: L("Code")
            case .design: L("A design")
            case .link: L("A link")
            case .prose: "Texto"
            }
        }
    }

    /// One thing the app can do with what it just recognised.
    public struct Offer: Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String
        public let symbol: String
        /// The AI verb or agent command behind it.
        public let verb: String

        public init(id: String, title: String, symbol: String, verb: String) {
            self.id = id
            self.title = title
            self.symbol = symbol
            self.verb = verb
        }
    }

    /// Recognises the subject from the text and where it came from.
    ///
    /// Deliberately built from cheap, explainable signals rather than a classifier: a person can
    /// look at the result and understand why the app thought it was an invoice, which matters far
    /// more here than a couple of points of accuracy.
    public static func subject(of context: ScreenContext) -> Subject {
        let text = context.text
        let lower = text.lowercased()

        if !context.path.isEmpty {
            let designExtensions = ["sketch", "fig", "psd", "ai", "xd", "png", "jpg", "jpeg"]
            if designExtensions.contains((context.path as NSString).pathExtension.lowercased()) {
                return .design
            }
        }

        let errorMarkers = ["error:", "exception", "traceback", "stack trace", "fatal",
                            "undefined is not", "segmentation fault", "panic:", "errno"]
        if errorMarkers.contains(where: lower.contains) { return .error }

        let invoiceMarkers = ["factura", "invoice", "iva", "vat", "subtotal", "nº de factura",
                              "total a pagar", "importe"]
        if invoiceMarkers.count(where: lower.contains) >= 2 { return .invoice }

        let emailMarkers = [L("from:"), "para:", "asunto:", "from:", "to:", "subject:", "re:", "fwd:"]
        if emailMarkers.count(where: lower.contains) >= 2 { return .email }

        // A table is rows that repeat the same separator. Two lines is a coincidence; four is a
        // table.
        let lines = text.split(separator: "\n").prefix(12)
        let separated = lines.count { $0.contains("\t") || $0.filter { $0 == "|" }.count >= 2 }
        if separated >= 4 { return .table }

        let codeMarkers = ["func ", "def ", "class ", "import ", "const ", "=> ", "};", "</"]
        if codeMarkers.count(where: lower.contains) >= 2 { return .code }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://"), !trimmed.contains(" ") {
            return .link
        }
        return .prose
    }

    /// The three things worth offering for what is on screen.
    ///
    /// Three, never ten. This appears over whatever someone is doing, and a long menu at that
    /// moment costs more attention than doing the thing by hand would have.
    public static func offers(for subject: Subject) -> [Offer] {
        switch subject {
        case .error:
            [
                .init(id: "explain-error", title: L("Explain this error"),
                      symbol: "questionmark.circle", verb: "explain"),
                .init(id: "fix-error", title: L("Tell me how to fix it"),
                      symbol: "wrench.and.screwdriver", verb: "fix-error"),
                .init(id: "search-error", title: L("Look it up on the web"),
                      symbol: "magnifyingglass", verb: "search-web"),
            ]
        case .invoice:
            [
                .init(id: "invoice-extract", title: "Saca importe, fecha y proveedor",
                      symbol: "doc.text.magnifyingglass", verb: "extract-invoice"),
                .init(id: "invoice-file", title: L("File it where it belongs"),
                      symbol: "folder", verb: "file-invoice"),
                .init(id: "invoice-remember", title: L("Keep it in the brain"),
                      symbol: "brain", verb: "remember"),
            ]
        case .email:
            [
                .init(id: "email-reply", title: L("Draft the reply"),
                      symbol: "arrowshape.turn.up.left", verb: "reply"),
                .init(id: "email-tasks", title: L("Pull out what they are asking for"),
                      symbol: "checklist", verb: "extract-tasks"),
                .init(id: "email-summarise", title: L("Sum it up"),
                      symbol: "text.redaction", verb: "summarise"),
            ]
        case .table:
            [
                .init(id: "table-anomalies", title: L("Find what stands out"),
                      symbol: "chart.line.uptrend.xyaxis", verb: "analyse-table"),
                .init(id: "table-summarise", title: L("Explain what it says"),
                      symbol: "text.redaction", verb: "summarise"),
                .init(id: "table-markdown", title: L("Turn it into Markdown"),
                      symbol: "tablecells", verb: "table"),
            ]
        case .code:
            [
                .init(id: "code-explain", title: L("Explain what it does"),
                      symbol: "questionmark.circle", verb: "explain"),
                .init(id: "code-review", title: L("Tell me what is wrong"),
                      symbol: "exclamationmark.triangle", verb: "review-code"),
                .init(id: "code-tasks", title: L("Pull out the tasks"),
                      symbol: "checklist", verb: "extract-tasks"),
            ]
        case .design:
            [
                .init(id: "design-tasks", title: L("Pull the tasks out of this"),
                      symbol: "checklist", verb: "extract-tasks"),
                .init(id: "design-describe", title: L("Describe what is there"),
                      symbol: "eye", verb: "describe-image"),
                .init(id: "design-copy", title: L("Extract the text"),
                      symbol: "text.quote", verb: "extract-text"),
            ]
        case .link:
            [
                .init(id: "link-open", title: "Ábrelo", symbol: "arrow.up.forward", verb: "open"),
                .init(id: "link-research", title: L("Look into it"),
                      symbol: "binoculars", verb: "research"),
                .init(id: "link-remember", title: L("Keep it in the brain"),
                      symbol: "brain", verb: "remember"),
            ]
        case .prose:
            [
                .init(id: "prose-summarise", title: L("Sum it up"),
                      symbol: "text.redaction", verb: "summarise"),
                .init(id: "prose-translate", title: L("Translate it"),
                      symbol: "character.book.closed", verb: "translate-es"),
                .init(id: "prose-tasks", title: L("Pull out the tasks"),
                      symbol: "checklist", verb: "extract-tasks"),
            ]
        }
    }

    /// Text worth acting on. OCR of a desktop returns menu bar items and window titles, and
    /// offering to summarise that makes the whole feature look stupid.
    public static let minimumLength = 12

    public static func isWorthOffering(_ context: ScreenContext) -> Bool {
        if !context.path.isEmpty { return true }
        let trimmed = context.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumLength else { return false }
        // A single word, however long, is a label rather than something to work on.
        return trimmed.split(whereSeparator: \.isWhitespace).count >= 3
    }

    /// The instruction for an offer that has no matching AI verb of its own.
    public static func instruction(for verb: String) -> String? {
        switch verb {
        case "fix-error":
            "Explain in two sentences why this error happens and give the concrete fix. If you are "
            + "missing information to be sure, say so rather than invent it."
        case "extract-invoice":
            "Pull out of this invoice: supplier, number, date, net, tax and total. "
            + "Return only those fields, one per line. If one is missing, write “not stated”."
        case "analyse-table":
            "Look at this table and point out what stands out: outliers, gaps, "
            + "totals that do not add up. If it all looks normal, say so."
        case "review-code":
            "Point out the real problems in this code: bugs, uncovered cases, risks. "
            + "No style comments."
        case "file-invoice":
            "Propose a filename and a folder to file this invoice under. Name format: "
            + "YYYY-MM-supplier-amount. Return only the line “folder/name.pdf”, "
            + "with no explanation."
        case "research":
            "Research what follows and return: what it is, who is behind it, who it is for, and two "
            + "alternatives. If you do not have enough information, say so rather than pad it out."
        case "describe-image":
            "Describe what is there, for somebody who is not looking at it."
        case "extract-text":
            "Return only the text that appears, in order, describing nothing."
        default:
            nil
        }
    }
}
