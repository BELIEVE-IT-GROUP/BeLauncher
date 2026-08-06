import Foundation

/// What each MCP tool actually does, once the dispatch is out of the way.
///
/// Split from `MCPServer` because the two failed for different reasons. The server was fine: the
/// handshake worked and four tools were announced. The tools were the problem — every one of them
/// read only the vault, so with a hundred and fifty passages indexed in the same database the
/// answer to any question was still "la memoria no tiene nada sobre X". Connected and useless at
/// the same time, which is worse than disconnected: a model that hears "no hay nada" concludes the
/// company never decided anything, and says so with confidence.
///
/// Two rules run through everything here:
///
/// - **Nothing is said without its source.** Every passage that comes out carries where it came
///   from, when it happened and by which route it surfaced. A quote with no origin is the model's
///   own words wearing someone else's.
/// - **A missing capability is never reported as a missing answer.** No embedding model means
///   "solo puedo buscar por palabras", never "no hay nada". Those two sentences lead a caller to
///   opposite conclusions and only one of them is true.
public enum MCPTools {

    /// Above this a tool call stops being context and starts being a database dump the caller
    /// pays for in tokens and reads none of.
    public static let maximumLimit = 20
    public static let defaultLimit = 8

    static func clamp(_ limit: Int?) -> Int {
        min(max(limit ?? defaultLimit, 1), maximumLimit)
    }

    // MARK: - What the brain can see right now

    /// The state of the index, so every answer can say what it was able to look at.
    struct Coverage: Sendable {
        let hasIndex: Bool
        let passages: Int
        let vectorised: Int
        let engine: String?
        let memories: Int

        /// The honest line. Present whenever the search that just ran was weaker than the search
        /// this tool is supposed to be able to run.
        ///
        /// English, always, and not through the string catalog. Everything in this file is read by
        /// another model, never by a person: these are the assistant's working notes about what it
        /// did and did not look at. Instruction-following is measurably better in English on every
        /// model this is likely to reach, and the caller relays the answer in whatever language the
        /// user is speaking anyway. The material quoted back stays in the language it was written
        /// in, which is the part that has to be preserved.
        var warning: String? {
            guard hasIndex else {
                return "Warning: the semantic index is not mounted in this session. I can only "
                     + "look at the deliberate memory in the vault, not the clipboard or the work "
                     + "graph. Anything missing here may well exist."
            }
            guard engine != nil else {
                return "Warning: there is no embedding model, so I am searching by words only. A "
                     + "paraphrase or a synonym will not show up even if it is in the brain. To fix "
                     + "it: `ollama pull bge-m3`."
            }
            if passages > 0, vectorised < passages {
                return "Warning: the index is still being built, \(vectorised) of \(passages) "
                     + "passages carry a vector. The rest are only findable by words."
            }
            return nil
        }

        /// Named places with counts, not a shrug. When the answer is "nada", the caller has to be
        /// able to tell an empty brain from a brain that was never asked properly.
        func whereILooked(_ query: String) -> String {
            var places = ["deliberate memory (\(memories) object(s))"]
            if hasIndex {
                places.append("the semantic index (\(passages) passage(s), \(vectorised) with a "
                            + "vector\(engine.map { ", engine \($0)" } ?? ", no engine"))")
            } else {
                places.append("the semantic index, which is unavailable")
            }
            return "I searched for “\(query)” in \(places.joined(separator: " and in "))."
        }
    }

    @MainActor
    static func coverage(_ context: MCPContext) -> Coverage {
        guard let brain = context.brain else {
            return Coverage(hasIndex: false, passages: 0, vectorised: 0, engine: nil,
                            memories: context.vault.objects().count)
        }
        let progress = brain.progress()
        return Coverage(hasIndex: true, passages: progress.passages,
                        vectorised: progress.vectorised, engine: progress.engine,
                        memories: context.vault.objects().count)
    }

    // MARK: - Keeping credentials in the process

    /// What takes the place of a line that carries a credential.
    ///
    /// Visible on purpose. Removing the line in silence would leave the caller reading an answer
    /// with a hole in it and no way to know there was one, which is the same lie as answering
    /// "no hay nada" when the index is not mounted.
    static let redactionMark = "[credential omitted]"

    /// Punctuation a rendered line wraps a value in. Stripped off each word before it is checked.
    private static let decoration = CharacterSet(
        charactersIn: "*_`~'\"“”‘’«»()[]{}<>,;:.…·—–- ")

    /// Whether one line carries a credential anywhere in it, not only at its start.
    ///
    /// `SecretGuard` reads the first word and the first `=`/`:` of what it is handed. That is the
    /// right rule for a clipboard entry and the wrong one for a line this file composed, which is
    /// why the gate leaked with the guard already in place: `**sk-ant-api03-…**` in a decision
    /// headline keeps its markdown as the first word, and `- 12:00 · Archivo · AKIA…` in the work
    /// log offers the colon of the timestamp as the first separator. Both passed a whole-line
    /// check while the same token alone did not. So the line is checked whole and then word by
    /// word with the decoration taken off.
    /// One rule for every door.
    ///
    /// This used to be its own tokeniser here, and a re-audit proved it still leaked: a PAT inside
    /// a git URL walked out of five tools verbatim. The rule now lives in `SecretGuard` so the
    /// clipboard, the index and this exit all refuse the same shapes — three copies of a security
    /// rule means the weakest copy decides.
    static func carriesSecret(_ line: String) -> Bool {
        SecretGuard.carriesSecret(line)
    }

    /// A passage that carries a credential never leaves over the wire.
    ///
    /// The index already refuses clips that look like secrets, but that guard runs on the way in
    /// and only covers the clipboard: a memory somebody typed or a work node named after a
    /// `.env` line reaches the index by another door. This is the second door, checked line by
    /// line because `SecretGuard` reads the first word of what it is handed and a token pasted in
    /// the middle of a paragraph passes a whole-text check.
    static func isSafeToSend(_ text: String) -> Bool {
        !text.split(whereSeparator: \.isNewline).contains { carriesSecret(String($0)) }
    }

    static func safe(_ hits: [Retrieved]) -> [Retrieved] {
        hits.filter { isSafeToSend($0.passage.text) && isSafeToSend($0.passage.title) }
    }

    /// The same rule applied to text that is leaving anyway: the line goes, the rest stays.
    ///
    /// `safe(_:)` can afford to drop a whole passage because another passage usually says the
    /// same thing. The tools that read the vault cannot: dropping a decision because one line of
    /// it is an API key would answer "no hay ninguna decisión registrada" about a decision that
    /// exists, and that is the one lie this file is built to avoid.
    static func redacted(_ text: String) -> String {
        // Untouched when there is nothing to remove, so a quote stays byte for byte the original.
        guard !isSafeToSend(text) else { return text }
        return text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { carriesSecret(String($0)) ? redactionMark : String($0) }
            .joined(separator: "\n")
    }

    /// Every reply leaves through here.
    ///
    /// The output is the last door and it used to cover three tools out of seven: `recall` and
    /// `context_for` filtered their passages while `search_memory`, `what_did_we_decide` and
    /// `prepare` rendered the vault straight onto the wire. A door that covers part of the wall
    /// is not a door.
    static func reply(_ text: String, isError: Bool = false) -> MCPServer.Response {
        MCPServer.Response(text: redacted(text), isError: isError)
    }

    // MARK: - recall

    /// Search by meaning across everything indexed, answered with cited passages.
    @MainActor
    public static func recall(query: String, limit: Int?,
                              context: MCPContext) async -> MCPServer.Response {
        let cover = coverage(context)
        guard let brain = context.brain else {
            return reply([cover.whereILooked(query), cover.warning]
                .compactMap { $0 }.joined(separator: "\n\n"))
        }

        let result = await brain.search(query, limit: clamp(limit))
        let hits = safe(result.hits)
        guard !hits.isEmpty else {
            return reply(nothingFound(query: query, cover: cover, result: result))
        }

        var lines = ["\(hits.count) passage(s) about “\(query)”. \(routeSummary(result))"]
        if let warning = cover.warning { lines.append(warning) }
        lines.append("")
        for (index, hit) in hits.enumerated() {
            lines.append(citation(index + 1, hit))
            lines.append("")
        }
        lines.append("Cite every claim with its [n]. Do not assume anything that is not here.")
        return reply(lines.joined(separator: "\n"))
    }

    // MARK: - context_for

    /// Everything the brain holds that bears on a task, grouped by origin and marked up so a
    /// model can tell a quotation from a label.
    ///
    /// The output is tagged rather than prose on purpose. The caller is another model that is
    /// about to rewrite a document out of this material, and the failure mode there is not
    /// missing context, it is a fluent result where half the sentences came from the notes and
    /// half from the model's own priors with no way left to tell which. Attributes carry the
    /// metadata, `<cita>` carries text that is literal and nothing else, and the numbering is
    /// global so `[n]` means one passage across the whole reply.
    @MainActor
    public static func contextFor(task: String, limit: Int?,
                                  context: MCPContext) async -> MCPServer.Response {
        let cover = coverage(context)
        guard let brain = context.brain else {
            return reply([cover.whereILooked(task), cover.warning]
                .compactMap { $0 }.joined(separator: "\n\n"))
        }

        // Asked wider than recall: assembling material for a rewrite wants the second-best
        // paragraph of a source too, where a question only wants the answer.
        let result = await brain.search(task, limit: min(clamp(limit) + 4, maximumLimit))
        let hits = safe(result.hits)
        guard !hits.isEmpty else {
            return reply(nothingFound(query: task, cover: cover, result: result))
        }

        // Ranked order decides which source comes first; reading order decides what comes first
        // inside it, because passages of one note quoted out of sequence read as contradictions.
        var order: [String] = []
        var groups: [String: [Retrieved]] = [:]
        for hit in hits {
            let key = hit.passage.source.key
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(hit)
        }

        var lines: [String] = []
        // Redacted before it is escaped, not after: inside `tarea="…"` the credential stops being
        // the first word of its line, which is the one place `carriesSecret` cannot see it either.
        lines.append("<contexto_para tarea=\"\(attribute(redacted(task)))\">")
        lines.append("  <cobertura pasajes=\"\(hits.count)\" fuentes=\"\(order.count)\" "
                   + "indice=\"\(cover.vectorised)/\(cover.passages) con vector\" "
                   + "motor=\"\(attribute(cover.engine ?? "ninguno"))\" "
                   + "vias=\"\(attribute(routeSummary(result)))\"/>")
        if let warning = cover.warning {
            lines.append("  <aviso>\(attribute(warning))</aviso>")
        }

        var number = 0
        for key in order {
            let group = (groups[key] ?? []).sorted { $0.passage.ordinal < $1.passage.ordinal }
            guard let first = group.first else { continue }
            let passage = first.passage
            lines.append("  <fuente tipo=\"\(attribute(passage.source.kind.label))\" "
                       + "titulo=\"\(attribute(redacted(passage.title)))\" "
                       + "fecha=\"\(isoDay(passage.occurredAt))\" "
                       + "ref=\"\(attribute(passage.source.key))\" "
                       + "via=\"\(route(first))\">")
            for hit in group {
                number += 1
                lines.append("    <cita n=\"\(number)\">")
                lines.append(quotable(hit.passage.text))
                lines.append("    </cita>")
            }
            lines.append("  </fuente>")
        }

        lines.append("""
              <como_usarlo>
              Lo que va dentro de <cita> es texto literal de la memoria de esta persona: úsalo, \
            cítalo o parafraséalo, pero no lo completes ni lo corrijas. Lo que va en los atributos \
            es metadato sobre la procedencia y no forma parte del documento. Cita cada afirmación \
            con [n]. Si este material no cubre alguna parte de la tarea, dilo en una línea en vez \
            de rellenar el hueco.
              </como_usarlo>
            """)
        lines.append("</contexto_para>")
        return reply(lines.joined(separator: "\n"))
    }

    // MARK: - what_was_i_doing

    /// The last stretch of work, from the graph and the clipboard, in time bands.
    @MainActor
    public static func whatWasIDoing(since: String?, context: MCPContext,
                                     date: Date = .now) -> MCPServer.Response {
        let from = moment(since, now: date)
        let nodes = context.store.nodes(limit: 500)
            .filter { $0.lastSeen >= from && $0.lastSeen <= date }
            .sorted { $0.lastSeen > $1.lastSeen }
        let clips = context.store.clips(limit: 200)
            .filter { $0.createdAt >= from && $0.createdAt <= date }
            .filter { isSafeToSend($0.text) }
            .sorted { $0.createdAt > $1.createdAt }

        var lines = ["Work since \(stamp(from)) (\(sinceLabel(since))). "
                   + "I looked at the work graph (\(nodes.count) node(s)) and the clipboard "
                   + "(\(clips.count) fragment(s))."]

        guard !nodes.isEmpty || !clips.isEmpty else {
            lines.append("")
            lines.append("Nothing is recorded in that stretch. Either no activity was captured, "
                       + "or the stretch is too short: try since=\"7d\".")
            return reply(lines.joined(separator: "\n"))
        }

        for band in Band.allCases {
            let bandNodes = nodes.filter { band.contains($0.lastSeen, now: date) }
            let bandClips = clips.filter { band.contains($0.createdAt, now: date) }
            guard !bandNodes.isEmpty || !bandClips.isEmpty else { continue }

            lines.append("")
            lines.append("## \(band.label)")
            if !bandNodes.isEmpty {
                lines.append("Work:")
                for node in bandNodes.prefix(12) {
                    // Field by field, so the row keeps its hour and its kind when the name is a
                    // `.env` line. A node named after one is how a credential reaches the graph
                    // without ever passing through the clipboard.
                    let detail = node.detail.isEmpty ? "" : " — \(redacted(node.detail))"
                    lines.append("- \(time(node.lastSeen)) · \(node.kind.label) · "
                               + "\(redacted(node.name))\(detail)")
                }
            }
            if !bandClips.isEmpty {
                lines.append("Clipboard (verbatim quote):")
                for clip in bandClips.prefix(8) {
                    lines.append("- \(time(clip.createdAt)) · «\(excerpt(clip.text))»"
                               + (clip.sourceApp.isEmpty ? "" : " · from \(clip.sourceApp)"))
                }
            }
        }

        lines.append("")
        lines.append("This is captured activity, not decisions. For what the company believes, "
                   + "use what_did_we_decide.")
        return reply(lines.joined(separator: "\n"))
    }

    /// Time bands rather than a flat list: "esta mañana" and "hace tres semanas" answer different
    /// questions, and a single reverse-chronological list hides which one you are looking at.
    enum Band: CaseIterable {
        case today
        case yesterday
        case thisWeek
        case earlier

        var label: String {
            switch self {
            case .today: "Today"
            case .yesterday: "Yesterday"
            case .thisWeek: "This week"
            case .earlier: "Antes"
            }
        }

        func contains(_ date: Date, now: Date) -> Bool {
            let calendar = Calendar.current
            switch self {
            case .today: return calendar.isDate(date, inSameDayAs: now)
            case .yesterday:
                guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else {
                    return false
                }
                return calendar.isDate(date, inSameDayAs: yesterday)
            case .thisWeek:
                return date > now.addingTimeInterval(-7 * 86_400)
                    && !Band.today.contains(date, now: now)
                    && !Band.yesterday.contains(date, now: now)
            case .earlier:
                return date <= now.addingTimeInterval(-7 * 86_400)
            }
        }
    }

    /// Accepts what a model would plausibly send: a duration, a day name, or a date.
    ///
    /// Anything unrecognised falls back to a day rather than to an error. A tool that refuses the
    /// call over the format of an optional argument turns a usable answer into a retry.
    static func moment(_ since: String?, now: Date) -> Date {
        guard let raw = since?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else {
            return now.addingTimeInterval(-86_400)
        }
        let calendar = Calendar.current
        if raw == "hoy" || raw == "today" { return calendar.startOfDay(for: now) }
        if raw == "ayer" || raw == "yesterday" {
            return calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) ?? now
        }
        // Zero is a legitimate answer: "0d" means "desde ahora mismo", and rejecting it sent the
        // caller a whole day of history when it had explicitly asked for none. A negative span is
        // a different thing and still falls back to the day.
        if let unit = raw.last, let amount = Double(raw.dropLast()), amount >= 0 {
            switch unit {
            case "h": return now.addingTimeInterval(-amount * 3_600)
            case "d": return now.addingTimeInterval(-amount * 86_400)
            case "w": return now.addingTimeInterval(-amount * 7 * 86_400)
            default: break
            }
        }
        if let parsed = try? Date(raw, strategy: .iso8601.year().month().day()
            .dateSeparator(.dash)) {
            return parsed
        }
        return now.addingTimeInterval(-86_400)
    }

    static func sinceLabel(_ since: String?) -> String {
        let raw = since?.trimmingCharacters(in: .whitespaces) ?? ""
        return raw.isEmpty ? "last 24 h" : raw
    }

    // MARK: - what_did_we_decide

    /// The decision in force, from the vault, backed by whatever the index can add.
    @MainActor
    public static func whatDidWeDecide(topic: String, context: MCPContext,
                                       date: Date = .now) async -> MCPServer.Response {
        let cover = coverage(context)
        let answer = BrainQuery.whatDidWeDecide(topic: topic, in: context.vault.objects(), at: date)
        let found = await passages(for: topic, context: context, excluding: answer.citations)

        // The vault knows: the index is supporting material, clearly labelled as such so nobody
        // mistakes a paragraph that mentions the price for the decision about the price.
        guard answer.citations.isEmpty else {
            var text = render(answer)
            if !found.hits.isEmpty {
                text += "\n\nContexto alrededor de esto (no son decisiones registradas):\n"
                text += found.hits.enumerated()
                    .map { citation($0.offset + 1, $0.element) }
                    .joined(separator: "\n\n")
            }
            if let warning = cover.warning { text += "\n\n\(warning)" }
            return reply(text)
        }

        // The vault does not know. Saying so is only useful if it also says what was searched:
        // "no hay ninguna decisión registrada" and "no pude buscar bien" are different facts.
        var lines = ["No decision is recorded about “\(topic)”.",
                     cover.whereILooked(topic)]
        if let warning = cover.warning { lines.append(warning) }
        if !found.hits.isEmpty {
            lines.append("")
            lines.append("The index does have nearby material. None of it is recorded as a "
                       + "decision, so treat it as context and not as the answer:")
            for (index, hit) in found.hits.enumerated() {
                lines.append("")
                lines.append(citation(index + 1, hit))
            }
        }
        return reply(lines.joined(separator: "\n"))
    }

    // MARK: - prepare

    /// Everything known about a person, client or project, vault first and index behind it.
    @MainActor
    public static func prepare(subject: String, context: MCPContext,
                               date: Date = .now) async -> MCPServer.Response {
        let cover = coverage(context)
        let answer = BrainQuery.prepare(subject: subject, in: context.vault.objects(),
                                        events: context.events, at: date)
        let found = await passages(for: subject, context: context, excluding: answer.citations)

        guard answer.citations.isEmpty, found.hits.isEmpty else {
            var text = answer.citations.isEmpty
                ? "## Nada registrado en la memoria deliberada sobre «\(subject)»"
                : render(answer)
            if !found.hits.isEmpty {
                text += "\n\nDe lo indexado (portapapeles, grafo de trabajo, notas):\n"
                text += found.hits.enumerated()
                    .map { citation($0.offset + 1, $0.element) }
                    .joined(separator: "\n\n")
            }
            if let warning = cover.warning { text += "\n\n\(warning)" }
            return reply(text)
        }

        var lines = ["Todavía no hay nada sobre «\(subject)».", cover.whereILooked(subject)]
        if !context.events.isEmpty {
            lines.append("También miré \(context.events.count) evento(s) del calendario.")
        }
        if let warning = cover.warning { lines.append(warning) }
        return reply(lines.joined(separator: "\n"))
    }

    // MARK: - search_memory

    /// The vault on its own, with the state of each object. Narrower than `recall` on purpose:
    /// this is the only tool that answers "¿sigue vigente?", which a passage cannot.
    @MainActor
    public static func searchMemory(query: String, includeSuperseded: Bool,
                                    context: MCPContext, date: Date = .now) -> MCPServer.Response {
        let cover = coverage(context)
        let found = BrainQuery.relevant(query, in: context.vault.objects(), kinds: nil)
            .filter { includeSuperseded || $0.isCurrent(at: date) }
            .prefix(10)
        guard !found.isEmpty else {
            return reply("""
                Deliberate memory holds no object about “\(query)” (\(cover.memories) \
                reviewed). This does not cover the clipboard or the work graph: for those, \
                use recall.
                """)
        }
        // Field by field so one memory written with a key in it does not take the rest of the
        // list with it: this is the only tool that answers "¿sigue vigente?", and answering "no
        // hay nada" because of one bad line would be read as "no está vigente".
        return reply(found.map { object in
            "- \(redacted(object.statement))\n  \(object.kind.rawValue) · "
            + "\(object.isCurrent(at: date) ? "in force" : "superseded")"
            + (object.owner.isEmpty ? "" : " · \(redacted(object.owner))")
            + (object.source.isEmpty ? "" : " · \(redacted(object.source))")
        }.joined(separator: "\n"))
    }

    // MARK: - propose_memory

    /// Proposes, and only proposes. Unchanged on purpose: an assistant may suggest what the
    /// company believes, never decide it.
    @MainActor
    public static func proposeMemory(arguments: [String: Any], context: MCPContext,
                                     date: Date = .now) -> MCPServer.Response {
        guard let statement = arguments["statement"] as? String,
              !statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return reply("The statement is missing.", isError: true)
        }
        let kind = MemoryObject.Kind(rawValue: arguments["kind"] as? String ?? "") ?? .note
        let object = MemoryObject(
            level: .extracted, kind: kind, statement: statement,
            source: arguments["source"] as? String ?? "Proposed by an assistant",
            createdAt: date, validFrom: date,
            entities: arguments["entities"] as? [String] ?? []
        )
        do {
            let commit = try context.vault.propose(object, reason: "Via MCP")
            let conflicts = commit.conflicts.isEmpty
                ? ""
                : " It would clash with \(commit.conflicts.count) memory/memories in force."
            return reply("Proposal recorded. A person has to confirm it in BeLauncher before it "
                       + "becomes part of the memory.\(conflicts)")
        } catch {
            return reply("Could not propose it: \(error)", isError: true)
        }
    }

    // MARK: - Shared rendering

    /// Runs the index for a vault-first tool, dropping passages that only repeat what was already
    /// cited from the vault.
    @MainActor
    static func passages(for query: String, context: MCPContext,
                         excluding cited: [MemoryObject]) async -> Retriever.Result {
        guard let brain = context.brain else {
            return Retriever.Result(hits: [], usedMeaning: false, usedWords: false)
        }
        let already = Set(cited.map { IndexedSource(kind: .memory, id: $0.id).key })
        let result = await brain.search(query, limit: defaultLimit)
        let hits = safe(result.hits)
            .filter { !already.contains($0.passage.source.key) }
            .prefix(5)
        return Retriever.Result(hits: Array(hits), usedMeaning: result.usedMeaning,
                                usedWords: result.usedWords, gap: result.gap)
    }

    static func nothingFound(query: String, cover: Coverage,
                             result: Retriever.Result) -> String {
        var lines = ["I found nothing about “\(query)”.", cover.whereILooked(query)]
        if let warning = cover.warning {
            lines.append(warning)
        } else if let gap = result.gap {
            lines.append(gap)
        }
        return lines.joined(separator: "\n")
    }

    /// One cited passage: where it came from, when, by which route, then the text.
    static func citation(_ number: Int, _ hit: Retrieved) -> String {
        // Redacted before it is cut: half a key is still a key, and a title that gets truncated at
        // seventy characters would hand over the half that matters.
        let clean = redacted(hit.passage.title)
        let title = clean.isEmpty ? "untitled" : String(clean.prefix(70))
        return "[\(number)] \(hit.passage.source.kind.label) · \(title) · "
             + "\(stamp(hit.passage.occurredAt)) · \(RecallResults.reason(hit))\n\(hit.passage.text)"
    }

    static func route(_ hit: Retrieved) -> String {
        switch hit.route {
        case .meaning: "meaning"
        case .words: "words"
        case .both: "meaning and words"
        case .related: "related"
        }
    }

    static func routeSummary(_ result: Retriever.Result) -> String {
        switch (result.usedMeaning, result.usedWords) {
        case (true, true): "Searched by meaning and by words."
        case (true, false): "Searched by meaning."
        case (false, true): "Searched by words only."
        case (false, false): "No matches by either route."
        }
    }

    static func render(_ answer: BrainQuery.Answer) -> String {
        var text = "## \(answer.headline)\n\n\(answer.body)"
        if let gap = answer.gap {
            text += "\n\n⚠︎ \(gap)"
        }
        if !answer.citations.isEmpty {
            text += "\n\nFuentes:\n"
            text += answer.citations.map { object in
                "- \(object.statement)"
                + (object.source.isEmpty ? "" : " (\(object.source))")
            }.joined(separator: "\n")
        }
        return text
    }

    // MARK: - Formatting

    static func stamp(_ date: Date) -> String {
        DateFormatter.retrievalStamp().string(from: date)
    }

    static func isoDay(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().dateSeparator(.dash))
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func excerpt(_ text: String, limit: Int = 140) -> String {
        let flat = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return flat.count <= limit ? flat : String(flat.prefix(limit)) + "…"
    }

    static func attribute(_ raw: String) -> String {
        raw.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: " ")
    }

    /// The passage travels verbatim.
    ///
    /// Entity-escaping the whole body was the first version and it was wrong: the caller is about
    /// to rewrite a document out of this text, and any quoted code, HTML or `<` in the original
    /// would come back mangled into the result. The only thing altered is a literal closing tag,
    /// which would otherwise end the block early and hand the model a truncated quote it has no
    /// way to notice.
    static func quotable(_ raw: String) -> String {
        raw.replacingOccurrences(of: "</cita>", with: "</ cita>")
            .replacingOccurrences(of: "</fuente>", with: "</ fuente>")
            .replacingOccurrences(of: "</contexto_para>", with: "</ contexto_para>")
    }
}
