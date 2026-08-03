import Foundation
import Testing
@testable import Corvo

@Test func alvoDeTesteEstaLigado() {
    #expect(Bundle(for: BundleAnchor.self).bundleIdentifier != nil)
}

final class BundleAnchor {}
