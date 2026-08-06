import Foundation

/// Installing an update without making the person do it.
///
/// Handing someone a DMG and asking them to drag the app over the old one is not an update, it is
/// homework. The app knows there is a new version, knows where it lives and knows where it is
/// installed; it should just say so and offer a button.
///
/// The part that is not negotiable is what happens between downloading and replacing. This code
/// overwrites the running application, so it refuses to install anything it has not verified is
/// signed by us and notarized by Apple. A downloader that trusts its own feed is a delivery
/// mechanism for whoever takes over the feed.
public struct UpdateInstaller: Sendable {

    /// Our Developer ID. Anything else, however well signed, is not this app.
    public static let expectedTeamIdentifier = "35R4W3WK5T"

    public enum Phase: Sendable, Equatable {
        case idle
        case downloading(fraction: Double)
        case verifying
        case installing
        /// Everything is in place; the app has to be relaunched to run the new version.
        case readyToRelaunch(version: String)
        case failed(String)

        public var isBusy: Bool {
            switch self {
            case .downloading, .verifying, .installing: true
            case .idle, .readyToRelaunch, .failed: false
            }
        }
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case notWritable(String)
        case translocated
        case badArchive
        case couldNotMount
        case notSignedByUs(found: String)
        case notNotarized
        case replaceFailed(String)

        public var description: String {
            switch self {
            case .notWritable(let path):
                L("%@ cannot be written to. Move BeLauncher to Applications and try again.", path)
            case .translocated:
                L("macOS is running the app from a read-only copy. Move it to Applications and open it from there.")
            case .badArchive:
                L("The download does not contain a BeLauncher app. Nothing was installed.")
            case .couldNotMount:
                L("The download could not be opened. It may have been cut off halfway; try again.")
            case .notSignedByUs(let found):
                L("The download is not signed by Believe (found: %@). ", found.isEmpty ? L("no signature") : found)
                + L("Nothing was installed.")
            case .notNotarized:
                L("Apple does not recognise the download as notarised. Nothing was installed.")
            case .replaceFailed(let reason):
                L("The application could not be replaced: %@", reason)
            }
        }
    }

    // MARK: - Checks that do not touch the disk

    /// macOS runs quarantined apps from a hidden read-only copy. Replacing the bundle there
    /// silently updates nothing: the next launch still opens the original.
    public static func isTranslocated(_ bundlePath: String) -> Bool {
        bundlePath.contains("/AppTranslocation/")
    }

    /// Pulls the team out of `codesign -dv --verbose=4` output, which writes to stderr as
    /// `TeamIdentifier=XXXXXXXXXX` (or `not set` for ad-hoc signatures).
    public static func teamIdentifier(fromCodesign output: String) -> String {
        for line in output.split(separator: "\n") where line.hasPrefix("TeamIdentifier=") {
            let value = String(line.dropFirst("TeamIdentifier=".count))
                .trimmingCharacters(in: .whitespaces)
            return value == "not set" ? "" : value
        }
        return ""
    }

    /// `spctl -a -t exec -vv` says `source=Notarized Developer ID` for a stapled, notarized build.
    /// Accepting a plain `accepted` is not enough: a locally signed build is also accepted on the
    /// machine that signed it.
    public static func isNotarized(fromSpctl output: String) -> Bool {
        output.contains("source=Notarized Developer ID")
    }

    public static func verify(codesignOutput: String, spctlOutput: String) -> Failure? {
        let team = teamIdentifier(fromCodesign: codesignOutput)
        guard team == expectedTeamIdentifier else { return .notSignedByUs(found: team) }
        guard isNotarized(fromSpctl: spctlOutput) else { return .notNotarized }
        return nil
    }

    /// Where the update has to land: the bundle that is running, not wherever the DMG suggests.
    public static func installTarget(bundlePath: String) -> Result<String, Failure> {
        guard !isTranslocated(bundlePath) else { return .failure(.translocated) }
        let parent = (bundlePath as NSString).deletingLastPathComponent
        guard FileManager.default.isWritableFile(atPath: parent) else {
            return .failure(.notWritable(parent))
        }
        return .success(bundlePath)
    }
}
