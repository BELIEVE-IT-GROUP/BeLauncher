import Foundation
@preconcurrency import Photos
import BeLauncherCore

struct BELPhotoActionInput: Codable, Sendable { let criteria: String }

struct PhotoActionHandler: BELActionHandler {
    let actionID = "photos.find"
    init?(definition: BELActionDefinition) {
        guard definition.id == actionID, definition.adapter == .publicAPI else { return nil }
    }
    func perform(input: Data) async throws -> BELActionResult {
        let criteria = try JSONDecoder().decode(BELPhotoActionInput.self, from: input).criteria
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            throw PhotoActionError.permission
        }
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
}
enum PhotoActionError: Error, Equatable { case permission, noMatches }
