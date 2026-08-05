import Foundation
import CryptoKit

public enum SafeFilename {
    private static let reserved: Set<String> = [".", "..", ""]

    /// Turns arbitrary user text into a filename that cannot escape its folder
    /// or collide with a special name. Used for exports and diagnostics.
    public static func make(_ raw: String, fallback: String = "belauncher-export", extension ext: String) -> String {
        var cleaned = raw
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
        cleaned = String(cleaned.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar) && scalar != "\0"
        })
        cleaned = cleaned
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        cleaned = String(cleaned.prefix(80))
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: ". "))

        let base = reserved.contains(cleaned) ? fallback : cleaned
        let suffix = ext.hasPrefix(".") ? ext : ".\(ext)"
        return base.hasSuffix(suffix) ? base : base + suffix
    }
}

enum Digest {
    static func sha256(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
