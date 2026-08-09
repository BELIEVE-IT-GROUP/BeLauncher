import Foundation
@preconcurrency import Photos
import BeLauncherCore

@MainActor
final class PhotoAccess {
    private(set) var photos: [PhotoItem] = []
    private var hasAsked = false
    var isAuthorised: Bool {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited:
            return true
        default:
            return false
        }
    }

    func requestAccessIfNeeded() async {
        guard !isAuthorised, !hasAsked else { return }
        hasAsked = true
        _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        refresh()
    }

    func refresh() {
        guard isAuthorised else { return }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 500
        let images = PHAsset.fetchAssets(with: .image, options: options)
        let videos = PHAsset.fetchAssets(with: .video, options: options)
        var mapped: [PhotoItem] = []
        let assets = (0..<images.count).map { images.object(at: $0) }
            + (0..<videos.count).map { videos.object(at: $0) }
        mapped = assets.map(makeItem)
        photos = mapped
    }

    /// Resolves an asset outside the 500-item launcher snapshot.
    /// This keeps a selected localIdentifier from becoming a false success when it is outside
    /// the launcher-facing recent window.
    func item(for assetID: String) -> PhotoItem? {
        guard isAuthorised,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject
        else { return nil }
        return makeItem(asset)
    }

    private func makeItem(_ asset: PHAsset) -> PhotoItem {
        let date = asset.creationDate?.formatted(date: .abbreviated, time: .omitted) ?? L("Photo")
        return PhotoItem(id: asset.localIdentifier, title: date,
                         album: L("Photo library"),
                         creationDate: asset.creationDate,
                         width: asset.pixelWidth, height: asset.pixelHeight,
                         isFavorite: asset.isFavorite,
                         mediaType: asset.mediaType == .video ? "video" : "image")
    }
}
