import Testing
import Foundation
@testable import BeLauncherCore

@Suite("Photos local metadata")
struct PhotoTests {
    @Test("photo metadata remains searchable without copying the original")
    func metadataIsInspectable() {
        let item = PhotoItem(id: "asset-1", title: "Aug 8, 2026", album: "Photo library",
                             path: "/Users/me/Pictures/Photos Library.photoslibrary/original.heic",
                             creationDate: Date(timeIntervalSince1970: 1_000), width: 1600,
                             height: 1200, isFavorite: true, mediaType: "image")
        #expect(item.searchableText.contains("favorite"))
        #expect(item.path.isEmpty)
        #expect(!item.searchableText.contains("original.heic"))
        #expect(item.width == 1600)
    }

    @Test("the photos slash route carries a stable asset identifier")
    func launcherKeepsAssetIdentity() throws {
        let input = SearchInput(
            photos: [PhotoItem(id: "asset-1", title: "Aug 8, 2026", album: "Photo library",
                               path: "/Users/me/Pictures/original.heic")],
            photosAuthorised: true)
        let result = try #require(SearchEngine.search("/photos", in: input).first)
        #expect(result.kind == .photo)
        #expect(result.payload == "asset-1")
    }

    @Test("opening a photo uses its stable asset identifier")
    func openUsesStableAssetIdentity() throws {
        let input = SearchInput(
            photos: [PhotoItem(id: "asset-1", title: "Aug 8, 2026", album: "Photo library",
                               path: "/Users/me/Pictures/original.heic")],
            photosAuthorised: true)
        let result = try #require(SearchEngine.search("/photos", in: input).first)
        #expect(ActionRegistry.actions(for: result).first?.intent
                == .systemCommand("bel:photos.open\u{1F}asset-1"))
    }

    @Test("keeping a photo runs through the stable confirmed action")
    func rememberUsesConfirmedStableAction() throws {
        let input = SearchInput(
            photos: [PhotoItem(id: "asset-1", title: "Aug 8, 2026", album: "Photo library",
                               path: "/Users/me/Pictures/original.heic")],
            photosAuthorised: true)
        let result = try #require(SearchEngine.search("/photos", in: input).first)
        let remember = try #require(ActionRegistry.actions(for: result).first { $0.id == "remember" })
        #expect(remember.intent == .systemCommand("bel:photos.remember\u{1F}asset-1"))

        let definition = try #require(BELActionCatalog.named("photos.remember"))
        #expect(definition.requiredCapabilities == [.photos])
        #expect(definition.alwaysConfirms)
        #expect(BELActionGate.decide(definition, capabilities: .allGranted) == .requiresConfirmation)
        #expect(BELActionGate.decide(definition, capabilities: .allGranted, confirmed: true) == .allowed)
    }

    @Test("photo actions do not trust a copied file payload")
    func actionRegistryDerivesStableAssetID() throws {
        let result = SearchResult(id: "photo-asset-1", kind: .photo,
                                  title: "Aug 8, 2026", subtitle: "Photo library",
                                  score: 100, matched: [],
                                  payload: "/Users/me/Pictures/original.heic")
        let actions = ActionRegistry.actions(for: result)
        #expect(actions.first { $0.id == "open" }?.intent
                == .systemCommand("bel:photos.open\u{1F}asset-1"))
        #expect(actions.first { $0.id == "remember" }?.intent
                == .systemCommand("bel:photos.remember\u{1F}asset-1"))
        #expect(actions.first { $0.id == "copy" }?.intent == .copy(text: "asset-1"))
    }
}
