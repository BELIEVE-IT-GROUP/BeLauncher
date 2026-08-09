import Foundation

public struct PhotoItem: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let album: String
    public let path: String
    public let creationDate: Date?
    public let width: Int
    public let height: Int
    public let isFavorite: Bool
    public let mediaType: String
    public init(id: String, title: String, album: String = "", path: String = "",
                creationDate: Date? = nil, width: Int = 0, height: Int = 0,
                isFavorite: Bool = false, mediaType: String = "image") {
        self.id = id; self.title = title; self.album = album; self.path = path
        self.creationDate = creationDate; self.width = width; self.height = height
        self.isFavorite = isFavorite; self.mediaType = mediaType
    }
    public var searchableText: String {
        let favorite = isFavorite ? "favorite" : ""
        return "\(title) \(album) \(path) \(mediaType) \(favorite)"
    }
}
