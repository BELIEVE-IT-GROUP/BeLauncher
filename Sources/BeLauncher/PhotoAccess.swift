import Foundation
@preconcurrency import Photos
import BeLauncherCore

@MainActor
final class PhotoAccess {
    private(set) var photos: [PhotoItem] = []
    private var hasAsked = false
    var isAuthorised: Bool {
        PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
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
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var mapped: [PhotoItem] = []
        result.enumerateObjects { asset, _, _ in
            let date = asset.creationDate?.formatted(date: .abbreviated, time: .omitted) ?? L("Photo")
            mapped.append(PhotoItem(id: asset.localIdentifier, title: date,
                                    album: L("Photo library")))
        }
        photos = mapped
    }
}
