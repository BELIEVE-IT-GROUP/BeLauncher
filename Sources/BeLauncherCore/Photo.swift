import Foundation

public struct PhotoItem: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let album: String
    public let path: String
    public init(id: String, title: String, album: String = "", path: String = "") {
        self.id = id; self.title = title; self.album = album; self.path = path
    }
    public var searchableText: String { "\(title) \(album) \(path)" }
}
