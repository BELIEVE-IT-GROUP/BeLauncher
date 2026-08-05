import Foundation

/// Workflows open URLs. That is the whole automation surface, on purpose:
/// no shell, no scripts, nothing that could execute untrusted content.
public enum WorkflowURL {
    public static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    public static func validateTemplate(_ template: String) throws {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ValidationError.badURLTemplate("the template is empty") }
        guard let scheme = trimmed.components(separatedBy: ":").first?.lowercased(),
              allowedSchemes.contains(scheme) else {
            throw ValidationError.badURLTemplate("only \(allowedSchemes.sorted().joined(separator: ", ")) are allowed")
        }
        // A template with no placeholder is fine (a plain bookmark), but it must still parse
        // once the placeholder is filled with something ordinary.
        guard build(template: trimmed, query: "test", secret: { _ in "test" }) != nil else {
            throw ValidationError.badURLTemplate("the result is not a valid URL")
        }
    }

    /// Substitutes `{query}` (percent-encoded) and `{secret:NAME}` then parses the result.
    /// Returns nil when the result is not a URL with an allowed scheme.
    public static func build(
        template: String,
        query: String,
        secret: (String) -> String? = { _ in nil }
    ) -> URL? {
        var filled = ""
        var index = template.startIndex
        while index < template.endIndex {
            guard template[index] == "{", let close = template[index...].firstIndex(of: "}") else {
                filled.append(template[index])
                index = template.index(after: index)
                continue
            }
            let token = String(template[template.index(after: index)..<close])
            if token.lowercased() == "query" {
                filled.append(encode(query))
            } else if token.lowercased().hasPrefix("secret:") {
                let name = String(token.dropFirst("secret:".count))
                filled.append(encode(secret(name) ?? ""))
            } else {
                filled.append("{\(token)}")
            }
            index = template.index(after: close)
        }

        guard let url = URL(string: filled),
              let scheme = url.scheme?.lowercased(),
              allowedSchemes.contains(scheme) else { return nil }
        return url
    }

    private static func encode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}
