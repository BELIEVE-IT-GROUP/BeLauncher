import Testing
import Foundation
@testable import BeLauncherCore

@Suite("Photos local metadata")
struct PhotoTests {
    @Test("photo metadata remains searchable without copying the original")
    func metadataIsInspectable() {
        let item = PhotoItem(id: "asset-1", title: "Aug 8, 2026", album: "Photo library",
                             creationDate: Date(timeIntervalSince1970: 1_000), width: 1600,
                             height: 1200, isFavorite: true, mediaType: "image")
        #expect(item.searchableText.contains("favorite"))
        #expect(item.path.isEmpty)
        #expect(item.width == 1600)
    }

    @Test("the photos slash route carries a stable asset identifier")
    func launcherKeepsAssetIdentity() throws {
        let input = SearchInput(
            photos: [PhotoItem(id: "asset-1", title: "Aug 8, 2026", album: "Photo library")],
            photosAuthorised: true)
        let result = try #require(SearchEngine.search("/photos", in: input).first)
        #expect(result.kind == .photo)
        #expect(result.payload == "asset-1")
    }
}
