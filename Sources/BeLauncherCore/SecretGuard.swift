import Foundation

/// Keeps credentials out of the clipboard history.
///
/// This exists because it happened: a live Stripe key was sitting in a real history, copied
/// from a terminal. Password managers mark their copies as concealed and are already ignored,
/// but a key pasted from a terminal or a dashboard carries no such marker.
///
/// The rule is deliberately conservative — it only skips text that is unmistakably a
/// credential, because silently dropping ordinary text would be worse than useless.
public enum SecretGuard {

    /// Prefixes that are credentials by construction, not by guesswork.
    static let tokenPrefixes = [
        "sk_live_", "sk_test_", "rk_live_", "pk_live_",   // Stripe
        "ghp_", "gho_", "ghu_", "ghs_", "ghr_",           // GitHub
        "github_pat_",
        "xoxb-", "xoxp-", "xoxa-", "xoxs-",               // Slack
        "sk-ant-", "sk-proj-", "sk-or-",                  // Anthropic / OpenAI / OpenRouter
        "AKIA", "ASIA",                                   // AWS access key ids
        "AIza",                                           // Google
        "shpat_", "shpss_",                               // Shopify
        "glpat-",                                         // GitLab
        "dop_v1_", "doo_v1_",                             // DigitalOcean
        "st_", "hf_", "npm_",
    ]

    /// Multi-line blocks that are never worth keeping.
    static let blockMarkers = [
        "-----BEGIN RSA PRIVATE KEY-----",
        "-----BEGIN OPENSSH PRIVATE KEY-----",
        "-----BEGIN PRIVATE KEY-----",
        "-----BEGIN EC PRIVATE KEY-----",
        "-----BEGIN PGP PRIVATE KEY BLOCK-----",
    ]

    /// Whether a credential appears anywhere inside this text, however it is wrapped.
    ///
    /// `looksLikeSecret` reads the first word and the first `=`/`:` of what it is handed, which is
    /// the right rule for a clipboard entry and the wrong one for a sentence somebody typed or a
    /// line this app composed. Two rounds of fixing this leaked anyway, and both times for the
    /// same reason: the check tokenised by a hand-written list of punctuation to strip. Measured
    /// escapes from the second attempt, every one of them a shape a real token takes:
    ///
    ///     https://ghp_…@github.com/acme/infra.git     (the usual way a PAT ends up in a note)
    ///     GITHUB_KEY=ghp_…        AUTH=sk-ant-…       (the name list had API_KEY but not KEY)
    ///     /Users/mac/.config/ghp_…                    (a path)
    ///
    /// So there is no list of decorations. A token can only contain letters, digits, `_` and `-`,
    /// so everything else is a boundary — by construction rather than by enumeration. Slashes,
    /// equals signs, at signs and quotes all separate, because none of them can be inside a token.
    public static func carriesSecret(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        if blockMarkers.contains(where: { text.contains($0) }) { return true }

        for line in text.split(whereSeparator: \.isNewline) {
            if looksLikeSecret(String(line)) { return true }

            for fragment in fragments(of: line) where fragment.count >= 20 {
                if tokenPrefixes.contains(where: { fragment.hasPrefix($0) }) { return true }
            }
            if namesASecret(line) { return true }
        }
        return false
    }

    /// Every run of characters that could be a token on its own.
    static func fragments(of text: Substring) -> [Substring] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "-" })
    }

    /// Words that announce what follows them is a credential.
    static let secretWords: Set<String> = [
        "SECRET", "TOKEN", "PASSWORD", "PASSWD", "PASS", "PWD", "KEY", "APIKEY", "AUTH",
        "AUTHORIZATION", "BEARER", "CREDENTIAL", "CREDENTIALS", "PAT", "PRIVATE", "SESSION",
        "COOKIE", "CLAVE", "CONTRASENA", "SECRETO",
    ]

    /// `SOMETHING_KEY=value`, where the name announces what the value is.
    ///
    /// Two things were wrong here and an audit measured both, which is worth writing down because
    /// the comment that used to sit in this spot claimed the opposite of what the code did:
    ///
    /// - It reused `fragments`, where `_` counts as part of a token. So `GITHUB_KEY` stayed a
    ///   single fragment, never matched `KEY`, and half the word list was unreachable for exactly
    ///   the compound names that credentials actually use. `SUPABASE_SERVICE_ROLE_KEY=…` walked
    ///   straight out.
    /// - It cut at the *first* `=` or `:`. In `Authorization: Bearer …` and in any URL, the first
    ///   colon belongs to something else, so the name it examined was never the name.
    ///
    /// Now the name is split on anything that is not a letter or a digit, and every separator on
    /// the line is tried rather than only the first.
    static func namesASecret(_ line: Substring) -> Bool {
        let characters = Array(line)
        for (index, character) in characters.enumerated() where character == "=" || character == ":" {
            // The name is the run of word characters immediately before the separator, which is
            // what makes `Authorization: Bearer x` and `?token=x` both readable.
            var start = index
            while start > 0, isWordCharacter(characters[start - 1]) { start -= 1 }
            guard start < index else { continue }
            let name = String(characters[start..<index])

            let after = String(characters[(index + 1)...]).trimmingCharacters(in: .whitespaces)
            // "Bearer <token>" and "Basic <blob>" put the value one word further along.
            let value = after.hasPrefix("Bearer ") || after.hasPrefix("Basic ")
                ? String(after.dropFirst(after.firstIndex(of: " ").map { after.distance(from: after.startIndex, to: $0) + 1 } ?? 0))
                : after

            guard looksOpaque(value) else { continue }
            let parts = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            if parts.contains(where: { secretWords.contains($0.uppercased()) }) { return true }
        }
        return credentialsInURL(line)
    }

    static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "-"
    }

    /// A value with no spaces and enough length to be a key rather than a setting.
    ///
    /// The whitespace rule is what keeps ordinary prose out: "Nota: hay que rotar la clave antes
    /// del viernes" has a long value and is not a credential, and dropping it in silence would
    /// leave somebody's memory with a hole they cannot see.
    static func looksOpaque(_ value: String) -> Bool {
        guard value.count >= 16, !value.contains(" ") else { return false }
        return value.contains(where: \.isNumber) || value.count >= 24
    }

    /// `postgres://user:password@host` and `https://admin:hunter2@panel`.
    ///
    /// A connection string is the single most damaging thing that can leave this app, and it looks
    /// nothing like a token: no prefix, no name, just a colon in the middle of a URL.
    static func credentialsInURL(_ line: Substring) -> Bool {
        guard let scheme = line.range(of: "://") else { return false }
        let rest = line[scheme.upperBound...]
        guard let at = rest.firstIndex(of: "@") else { return false }
        let authority = rest[rest.startIndex..<at]
        // Stop at the first slash: an `@` further into the path is an email in a URL, not a login.
        guard !authority.contains("/"), let colon = authority.firstIndex(of: ":") else { return false }
        let password = authority[authority.index(after: colon)...]
        return password.count >= 4
    }

    public static func looksLikeSecret(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if blockMarkers.contains(where: { trimmed.contains($0) }) { return true }

        // A bare token: one word, long, with a known prefix.
        let firstWord = trimmed.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? trimmed
        if firstWord.count >= 20, tokenPrefixes.contains(where: { firstWord.hasPrefix($0) }) {
            return true
        }

        // `EXPORT_NAME=value` / `SOME_SECRET: value` where the name itself says secret.
        if let separator = trimmed.firstIndex(where: { $0 == "=" || $0 == ":" }) {
            let name = trimmed[trimmed.startIndex..<separator]
                .replacingOccurrences(of: "export ", with: "")
                .trimmingCharacters(in: .whitespaces)
                .uppercased()
            let value = trimmed[trimmed.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            let sensitive = ["SECRET", "TOKEN", "PASSWORD", "PASSWD", "API_KEY", "APIKEY",
                             "PRIVATE_KEY", "ACCESS_KEY", "CLIENT_SECRET", "CREDENTIAL"]
            if name.count <= 60, !value.isEmpty,
               sensitive.contains(where: { name.contains($0) }) {
                return true
            }
        }

        // A JWT: three base64url segments.
        if firstWord.hasPrefix("eyJ"), firstWord.split(separator: ".").count == 3, firstWord.count >= 40 {
            return true
        }

        return false
    }
}
