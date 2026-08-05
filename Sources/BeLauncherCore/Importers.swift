import Foundation

/// Bringing snippets and quicklinks over from Alfred and Raycast.
///
/// Nobody switches launcher if it means retyping years of shortcuts, so this reads the formats
/// those apps already produce. Parsing is pure and the results are validated like anything the
/// user typed: an imported entry gets no special trust.
public enum Importers {

    public struct Result: Sendable, Equatable {
        public var snippets: [Snippet] = []
        public var workflows: [Workflow] = []
        /// Entries that were skipped, with the reason, so an import never fails in silence.
        public var skipped: [String] = []
    }

    // MARK: - Alfred

    public static var alfredSnippetsFolder: String {
        NSHomeDirectory()
            + "/Library/Application Support/Alfred/Alfred.alfredpreferences/snippets"
    }

    /// Alfred keeps one JSON file per snippet, grouped in collection folders.
    public static func parseAlfredSnippet(_ data: Data) -> Snippet? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = root["alfredsnippet"] as? [String: Any],
              let body = entry["snippet"] as? String, !body.isEmpty else { return nil }

        let name = (entry["name"] as? String) ?? ""
        let keyword = (entry["keyword"] as? String) ?? ""
        let resolved = keyword.isEmpty ? slug(name) : keyword
        guard !resolved.isEmpty else { return nil }

        return Snippet(keyword: resolved, title: name.isEmpty ? resolved : name,
                       body: convertPlaceholders(body))
    }

    public static func importAlfredSnippets(from folder: String? = nil) -> Result {
        let root = folder ?? alfredSnippetsFolder
        var result = Result()
        let manager = FileManager.default
        guard let walker = manager.enumerator(atPath: root) else { return result }

        for case let relative as String in walker where relative.hasSuffix(".json") {
            let path = (root as NSString).appendingPathComponent(relative)
            guard let data = manager.contents(atPath: path) else { continue }
            if let snippet = parseAlfredSnippet(data) {
                result.snippets.append(snippet)
            } else {
                result.skipped.append((relative as NSString).lastPathComponent)
            }
        }
        return result
    }

    // MARK: - Raycast

    /// Raycast exports snippets and quicklinks as a JSON array.
    public static func parseRaycastExport(_ data: Data) -> Result {
        var result = Result()
        guard let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return result
        }

        for entry in entries {
            let name = (entry["name"] as? String) ?? ""
            let keyword = (entry["keyword"] as? String) ?? slug(name)

            // A quicklink carries a link; a snippet carries text.
            if let link = entry["link"] as? String ?? entry["url"] as? String {
                let template = link.replacingOccurrences(of: "{argument}", with: "{query}")
                    .replacingOccurrences(of: "{Query}", with: "{query}")
                guard !keyword.isEmpty, (try? WorkflowURL.validateTemplate(template)) != nil else {
                    result.skipped.append(name.isEmpty ? link : name)
                    continue
                }
                result.workflows.append(Workflow(keyword: keyword,
                                                 title: name.isEmpty ? keyword : name,
                                                 urlTemplate: template))
                continue
            }

            if let text = entry["text"] as? String, !text.isEmpty, !keyword.isEmpty {
                result.snippets.append(Snippet(keyword: keyword,
                                               title: name.isEmpty ? keyword : name,
                                               body: convertPlaceholders(text)))
                continue
            }

            result.skipped.append(name.isEmpty ? "entrada sin nombre" : name)
        }
        return result
    }

    // MARK: - Shared

    /// Alfred and Raycast placeholders that have an exact equivalent here. Anything else is left
    /// as written: visible and wrong beats silently dropped.
    static func convertPlaceholders(_ body: String) -> String {
        let equivalents = [
            "{clipboard}": "{clipboard}",
            "{cursor}": "{cursor}",
            "{date}": "{date}",
            "{time}": "{time}",
            "{uuid}": "{uuid}",
            "{argument}": "{query}",
            "{query}": "{query}",
            "{snippet}": "",
        ]
        var converted = body
        for (source, target) in equivalents {
            converted = converted.replacingOccurrences(
                of: source, with: target, options: .caseInsensitive
            )
        }
        return converted
    }

    /// A keyword out of a human name: lower case, no spaces, no punctuation.
    static func slug(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let cleaned = folded.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
            .reduce(into: "") { $0.append($1) }
        return cleaned
            .split(separator: "-")
            .joined(separator: "-")
            .lowercased()
    }
}

extension Store {
    /// Imports without ever overwriting: an existing keyword wins, and the caller is told how
    /// many were skipped.
    @discardableResult
    public func apply(_ imported: Importers.Result) -> ImportSummary {
        var summary = ImportSummary()
        summary.skipped = imported.skipped.count

        for snippet in imported.snippets {
            do {
                try addSnippet(keyword: snippet.keyword, title: snippet.title, body: snippet.body)
                summary.addedSnippets += 1
            } catch {
                summary.skipped += 1
            }
        }
        for workflow in imported.workflows {
            do {
                try addWorkflow(keyword: workflow.keyword, title: workflow.title,
                                urlTemplate: workflow.urlTemplate)
                summary.addedWorkflows += 1
            } catch {
                summary.skipped += 1
            }
        }
        return summary
    }
}
