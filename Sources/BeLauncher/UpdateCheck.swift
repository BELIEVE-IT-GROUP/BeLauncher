import Foundation

/// Opt-in and inert by default: without an explicit toggle *and* a feed URL in `.env`,
/// BeLauncher never touches the network. There is no telemetry of any kind.
struct Release: Decodable, Sendable {
    let version: String
    let url: String
    let notes: String?
}

enum UpdateCheck {
    enum Outcome: Sendable {
        case notConfigured
        case upToDate
        case available(Release)
        case unavailable(String)   // offline, bad JSON, HTTP error — always recoverable
    }

    static func run(feedURL: String?, currentVersion: String) async -> Outcome {
        guard let feedURL, let url = URL(string: feedURL), url.scheme?.hasPrefix("http") == true else {
            return .notConfigured
        }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return .unavailable("The update feed replied with HTTP \(http.statusCode).")
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            return isNewer(release.version, than: currentVersion) ? .available(release) : .upToDate
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left != right { return left > right }
        }
        return false
    }
}
