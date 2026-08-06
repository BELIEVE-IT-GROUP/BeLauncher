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

    /// `SOMETHING_KEY=value`, where the name itself announces what the value is.
    ///
    /// Matched on the *components* of the name rather than on the whole string: `GITHUB_KEY`
    /// splits into `GITHUB` and `KEY` and trips, while `MONKEY` stays one component and does not.
    /// Substring matching would have flagged the second, and dropping ordinary text in silence is
    /// the failure this whole guard is written to avoid.
    static func namesASecret(_ line: Substring) -> Bool {
        let words = ["SECRET", "TOKEN", "PASSWORD", "PASSWD", "PWD", "KEY", "APIKEY",
                     "AUTH", "CREDENTIAL", "CREDENTIALS", "PAT"]
        guard let separator = line.firstIndex(where: { $0 == "=" || $0 == ":" }) else { return false }
        let name = line[line.startIndex..<separator]
        let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        // A value of a handful of characters is a setting, not a credential. Without this, a note
        // reading "clave: 4" would be dropped.
        guard value.count >= 12, name.count <= 60 else { return false }
        return fragments(of: name).contains { words.contains($0.uppercased()) }
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
