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
