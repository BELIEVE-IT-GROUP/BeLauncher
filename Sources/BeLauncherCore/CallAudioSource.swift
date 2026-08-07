import Foundation

/// The source used for call capture. Automatic mode is a suggestion layer: it never starts a
/// recording by itself, it only chooses the most likely app when the user presses Record call.
public enum CallAudioSource: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case zoom
    case teams
    case meet
    case system

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .automatic: L("Automatic")
        case .zoom: "Zoom"
        case .teams: "Microsoft Teams"
        case .meet: "Google Meet"
        case .system: L("Full system audio")
        }
    }

    public var bundleIdentifiers: Set<String> {
        switch self {
        case .zoom: ["us.zoom.xos"]
        case .teams: ["com.microsoft.teams2", "com.microsoft.teams"]
        case .meet: ["com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "com.brave.Browser"]
        case .automatic, .system: []
        }
    }
}
