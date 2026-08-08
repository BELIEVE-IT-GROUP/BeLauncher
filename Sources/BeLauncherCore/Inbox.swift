import Foundation

/// A reviewable capture in the Brain. This is deliberately a projection over the original source,
/// not a second copy of it: paths and clip ids remain the authority.
public struct InboxItem: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case note
        case evidence
        case clipboard
    }

    public enum State: String, Sendable, Equatable {
        case pending
        case needsTranscription
    }

    public let id: String
    public let kind: Kind
    public let state: State
    public let title: String
    public let excerpt: String
    public let sourcePath: String?
    public let clipID: Int64?
    public let sourceApp: String?
    public let createdAt: Date?

    public init(record: QuickNote.Record) {
        id = record.id
        kind = record.kind == .evidence ? .evidence : .note
        state = record.state == .needsTranscription ? .needsTranscription : .pending
        title = record.title
        excerpt = record.excerpt
        sourcePath = record.sourcePath ?? record.path
        clipID = nil
        sourceApp = nil
        createdAt = record.createdAt
    }

    public init(clip: Clip) {
        id = "clip:\(clip.id)"
        kind = .clipboard
        state = .pending
        title = clip.sourceApp.isEmpty ? "Clipboard capture" : clip.sourceApp
        excerpt = clip.text
        sourcePath = clip.assetPath.isEmpty ? nil : clip.assetPath
        clipID = clip.id
        sourceApp = clip.sourceApp.isEmpty ? nil : clip.sourceApp
        createdAt = clip.createdAt
    }
}
