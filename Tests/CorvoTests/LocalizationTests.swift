import Foundation
import Testing
@testable import Corvo

/// The app bundle. The test bundle is hosted by `Corvo.app` (TEST_HOST), so any
/// class of the Corvo module resolves to the bundle that ships the catalog.
private var appBundle: Bundle { Bundle(for: BlobStore.self) }

@Test func theAppIsEnglishFirstWithBrazilianPortugueseRegistered() {
    // Guards the premise of the two assertions below: drop TEST_HOST from the
    // test target and this file keeps compiling and passing while silently
    // measuring the test runner's bundle instead of the app's.
    #expect(appBundle.bundleIdentifier == "com.wylp.corvo")

    #expect(appBundle.developmentLocalization == "en")
    #expect(appBundle.localizations.contains("pt-BR"))
}
