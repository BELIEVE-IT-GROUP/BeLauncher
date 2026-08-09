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
        let assets = PHAsset.fetchAssets(with: .image, options: nil)
        let normalized = criteria.trimmingCharacters(in: .whitespacesAndNewlines)
        let count = assets.count
        // Photos has no filename search API. For now, a date fragment is the only deterministic
        // metadata query we can support without requesting original image data.
        let matching = normalized.isEmpty ? count : (0..<count).reduce(into: 0) { total, index in
            let asset = assets.object(at: index)
            let date = asset.creationDate?.formatted(date: .abbreviated, time: .omitted) ?? ""
            if date.localizedCaseInsensitiveContains(normalized) { total += 1 }
        }
        guard matching > 0 else { throw PhotoActionError.noMatches }
        return BELActionResult(text: L("%@ photos available locally", String(matching)), receipt: "photos:find")
    }
}
enum PhotoActionError: Error, Equatable { case permission, noMatches }
