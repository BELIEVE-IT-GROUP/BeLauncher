import Testing
import Foundation
@testable import BeLauncherCore

@Suite("Update check")
struct UpdateCheckTests {

    @Test("version comparison handles the shapes we actually ship")
    func versionOrdering() {
        #expect(UpdateCheck.isNewer("0.4.0", than: "0.3.1"))
        #expect(UpdateCheck.isNewer("0.3.2", than: "0.3.1"))
        #expect(UpdateCheck.isNewer("1.0.0", than: "0.9.9"))
        #expect(UpdateCheck.isNewer("0.10.0", than: "0.9.0"))   // not a string comparison
        #expect(!UpdateCheck.isNewer("0.3.1", than: "0.3.1"))
        #expect(!UpdateCheck.isNewer("0.3.0", than: "0.3.1"))
        #expect(!UpdateCheck.isNewer("0.3.1", than: "0.4.0"))
    }

    @Test("the feed URL ships as a default — it used to come only from .env, which nobody has")
    func feedHasADefault() {
        #expect(UpdateCheck.defaultFeedURL == "https://files.believe-global.com/apps/belauncher/latest.json")
        #expect(URL(string: UpdateCheck.defaultFeedURL)?.scheme == "https")
    }

    @Test("an empty or non-http feed is 'not configured', never a false 'up to date'")
    func rejectsBadFeeds() async {
        #expect(await UpdateCheck.run(feedURL: nil, currentVersion: "0.1.0") == .notConfigured)
        #expect(await UpdateCheck.run(feedURL: "", currentVersion: "0.1.0") == .notConfigured)
        #expect(await UpdateCheck.run(feedURL: "file:///tmp/x.json", currentVersion: "0.1.0") == .notConfigured)
    }

    /// Hits the real feed. It is the whole point of this feature: a version check that cannot
    /// reach the server is worthless, and this is the check that would have caught the bug.
    @Test("the live feed answers and reports an update for an older version")
    func liveFeed() async {
        let outcome = await UpdateCheck.run(feedURL: UpdateCheck.defaultFeedURL, currentVersion: "0.0.1")
        switch outcome {
        case .available(let release):
            #expect(release.url.hasSuffix(".dmg"))
            #expect(release.version.split(separator: ".").count == 3)
        case .unavailable(let reason):
            // Offline CI should not fail the suite, but say so out loud.
            Issue.record("the feed was unreachable: \(reason)")
        default:
            Issue.record("expected an update to be available for 0.0.1, got \(outcome)")
        }
    }

    @Test("a current build is told it is up to date")
    func liveFeedUpToDate() async {
        let outcome = await UpdateCheck.run(feedURL: UpdateCheck.defaultFeedURL, currentVersion: "999.0.0")
        if case .unavailable(let reason) = outcome {
            Issue.record("the feed was unreachable: \(reason)")
            return
        }
        #expect(outcome == .upToDate)
    }
}
