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
            case .selection: "lo que tienes seleccionado"
            case .recognised: "lo que hay en pantalla"
            case .file: "el archivo abierto"
            case .clipboard: "lo que copiaste"
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
            case .error: "Un error"
            case .invoice: "Una factura"
            case .email: "Un correo"
            case .table: "Una tabla"
            case .code: "Código"
            case .design: "Un diseño"
            case .link: "Un enlace"
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

        let emailMarkers = ["de:", "para:", "asunto:", "from:", "to:", "subject:", "re:", "fwd:"]
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
                .init(id: "explain-error", title: "Explícame este error",
                      symbol: "questionmark.circle", verb: "explain"),
                .init(id: "fix-error", title: "Dime cómo se arregla",
                      symbol: "wrench.and.screwdriver", verb: "fix-error"),
                .init(id: "search-error", title: "Búscalo en la web",
                      symbol: "magnifyingglass", verb: "search-web"),
            ]
        case .invoice:
            [
                .init(id: "invoice-extract", title: "Saca importe, fecha y proveedor",
                      symbol: "doc.text.magnifyingglass", verb: "extract-invoice"),
                .init(id: "invoice-file", title: "Archívala donde toca",
                      symbol: "folder", verb: "file-invoice"),
                .init(id: "invoice-remember", title: "Guárdalo en el cerebro",
                      symbol: "brain", verb: "remember"),
            ]
        case .email:
            [
                .init(id: "email-reply", title: "Redáctame la respuesta",
                      symbol: "arrowshape.turn.up.left", verb: "reply"),
                .init(id: "email-tasks", title: "Saca lo que me piden",
                      symbol: "checklist", verb: "extract-tasks"),
                .init(id: "email-summarise", title: "Resúmelo",
                      symbol: "text.redaction", verb: "summarise"),
            ]
        case .table:
            [
                .init(id: "table-anomalies", title: "Busca lo que se sale de la norma",
                      symbol: "chart.line.uptrend.xyaxis", verb: "analyse-table"),
                .init(id: "table-summarise", title: "Explícame qué dice",
                      symbol: "text.redaction", verb: "summarise"),
                .init(id: "table-markdown", title: "Pásala a Markdown",
                      symbol: "tablecells", verb: "table"),
            ]
        case .code:
            [
                .init(id: "code-explain", title: "Explícame qué hace",
                      symbol: "questionmark.circle", verb: "explain"),
                .init(id: "code-review", title: "Dime qué está mal",
                      symbol: "exclamationmark.triangle", verb: "review-code"),
                .init(id: "code-tasks", title: "Sácame las tareas",
                      symbol: "checklist", verb: "extract-tasks"),
            ]
        case .design:
            [
                .init(id: "design-tasks", title: "Saca las tareas de esto",
                      symbol: "checklist", verb: "extract-tasks"),
                .init(id: "design-describe", title: "Descríbeme lo que se ve",
                      symbol: "eye", verb: "describe-image"),
                .init(id: "design-copy", title: "Extrae los textos",
                      symbol: "text.quote", verb: "extract-text"),
            ]
        case .link:
            [
                .init(id: "link-open", title: "Ábrelo", symbol: "arrow.up.forward", verb: "open"),
                .init(id: "link-research", title: "Investígalo",
                      symbol: "binoculars", verb: "research"),
                .init(id: "link-remember", title: "Guárdalo en el cerebro",
                      symbol: "brain", verb: "remember"),
            ]
        case .prose:
            [
                .init(id: "prose-summarise", title: "Resúmelo",
                      symbol: "text.redaction", verb: "summarise"),
                .init(id: "prose-translate", title: "Tradúcelo",
                      symbol: "character.book.closed", verb: "translate-es"),
                .init(id: "prose-tasks", title: "Saca las tareas",
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
            "Explica en dos frases por qué ocurre este error y da el arreglo concreto. Si falta "
            + "información para estar seguro, dilo en vez de inventarlo."
        case "extract-invoice":
            "Extrae de esta factura: proveedor, número, fecha, base imponible, impuestos y total. "
            + "Devuelve solo esos campos, uno por línea. Si alguno no aparece, escribe «no consta»."
        case "analyse-table":
            "Mira esta tabla y señala lo que se sale de la norma: valores atípicos, huecos, "
            + "totales que no cuadran. Si todo es normal, dilo."
        case "review-code":
            "Señala los problemas reales de este código: fallos, casos no cubiertos, riesgos. "
            + "Nada de comentarios de estilo."
        case "file-invoice":
            "Propón un nombre de archivo y una carpeta para guardar esta factura. Formato del "
            + "nombre: AAAA-MM-proveedor-importe. Devuelve solo la línea «carpeta/nombre.pdf», "
            + "sin explicaciones."
        case "research":
            "Investiga lo que sigue y devuelve: qué es, quién está detrás, para quién sirve y dos "
            + "alternativas. Si no tienes información suficiente, dilo en vez de rellenar."
        case "describe-image":
            "Describe lo que se ve, para alguien que no lo está mirando."
        case "extract-text":
            "Devuelve solo los textos que aparecen, en orden, sin describir nada."
        default:
            nil
        }
    }
}
