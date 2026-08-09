import Foundation
@preconcurrency import Photos
import BeLauncherCore

struct BELPhotoActionInput: Codable, Sendable {
    let criteria: String
    let assetID: String?
    let albumName: String?
    init(criteria: String = "", assetID: String? = nil, albumName: String? = nil) {
        self.criteria = criteria
        self.assetID = assetID
        self.albumName = albumName
    }
}

struct PhotoActionHandler: BELActionHandler {
    let actionID: String
    init?(definition: BELActionDefinition) {
        guard ["photos.find", "photos.add_to_album"].contains(definition.id),
              definition.adapter == .publicAPI else { return nil }
        actionID = definition.id
    }
    func perform(input: Data) async throws -> BELActionResult {
        let value = try JSONDecoder().decode(BELPhotoActionInput.self, from: input)
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            throw PhotoActionError.permission
        }
        if actionID == "photos.add_to_album" {
            guard let assetID = value.assetID, !assetID.isEmpty,
                  let albumName = value.albumName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !albumName.isEmpty,
                  let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject
            else { throw PhotoActionError.invalidInput }
            let albums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
            var album: PHAssetCollection?
            albums.enumerateObjects { candidate, _, stop in
                if candidate.localizedTitle?.localizedCaseInsensitiveCompare(albumName) == .orderedSame {
                    album = candidate
                    stop.pointee = true
                }
            }
            guard let album else { throw PhotoActionError.albumNotFound }
            try await Self.performChanges {
                PHAssetCollectionChangeRequest(for: album)?.addAssets([asset] as NSArray)
            }
            return BELActionResult(text: L("Added to album: %@", albumName),
                                   changed: [assetID], receipt: "photos:add-to-album:\(assetID)")
        }
        let criteria = value.criteria
        let imageResult = PHAsset.fetchAssets(with: .image, options: nil)
        let videoResult = PHAsset.fetchAssets(with: .video, options: nil)
        let assets = (0..<imageResult.count).map { imageResult.object(at: $0) }
            + (0..<videoResult.count).map { videoResult.object(at: $0) }
        let normalized = criteria.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = (0..<assets.count).reduce(into: [PHAsset]()) { found, index in
            let asset = assets[index]
            let date = asset.creationDate?.formatted(date: .abbreviated, time: .omitted) ?? ""
            let asksFavorite = ["favorite", "favorites", "favorita", "favoritas"].contains(normalized)
            let asksVideo = ["video", "videos"].contains(normalized)
            let matches = normalized.isEmpty
                || (asksFavorite && asset.isFavorite)
                || (asksVideo && asset.mediaType == .video)
                || date.localizedCaseInsensitiveContains(normalized)
            if matches { found.append(asset) }
        }
        guard !matching.isEmpty else { throw PhotoActionError.noMatches }
        let first = matching.first?.localIdentifier ?? ""
        return BELActionResult(text: L("%@ photos available locally", String(matching.count)),
                               changed: first.isEmpty ? [] : [first], receipt: "photos:find")
    }

    private static func performChanges(_ changes: @escaping () -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges(changes) { success, error in
                if let error { continuation.resume(throwing: error) }
                else if success { continuation.resume() }
                else { continuation.resume(throwing: PhotoActionError.changeFailed) }
            }
        }
    }
}
enum PhotoActionError: Error, Equatable { case permission, noMatches, albumNotFound, invalidInput, changeFailed }
