import Foundation
import Testing
@testable import Corvo

/// The app bundle. The test bundle is hosted by `Corvo.app` (TEST_HOST), so any
/// class of the Corvo module resolves to the bundle that ships the catalog.
private var appBundle: Bundle { Bundle(for: BlobStore.self) }

@Test func theAppIsEnglishFirstWithBrazilianPortugueseRegistered() {
    #expect(appBundle.developmentLocalization == "en")
    #expect(appBundle.localizations.contains("pt-BR"))
}
