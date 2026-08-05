import Foundation
import Testing
@testable import Corvo

/// The panel itself cannot be exercised without a user in front of it. What can
/// is everything on either side of it: the `.app` the panel hands back becomes a
/// bundle id here, and the picker's list is built here.

/// A real bundle on disk, because that is what `Bundle(url:)` reads. Each one
/// gets its own directory: `Bundle` caches by path, and a reused path would
/// serve the previous test's `Info.plist`.
private func makeAppBundle(identifier: String?) throws -> URL {
    let app = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("corvo-tests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("Fake.app", isDirectory: true)
    let contents = app.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)

    var info: [String: Any] = ["CFBundleName": "Fake", "CFBundlePackageType": "APPL"]
    if let identifier { info["CFBundleIdentifier"] = identifier }
    let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try plist.write(to: contents.appendingPathComponent("Info.plist"))
    return app
}

@Test @MainActor func theChosenAppIsReducedToItsBundleId() throws {
    let app = try makeAppBundle(identifier: "com.wylp.fake")

    #expect(AppChooser.bundleId(forApplicationAt: app) == "com.wylp.fake")
}

@Test @MainActor func anAppBundleWithNoIdentifierYieldsNothing() throws {
    let app = try makeAppBundle(identifier: nil)

    #expect(AppChooser.bundleId(forApplicationAt: app) == nil)
}

@Test @MainActor func somethingThatIsNotAnAppYieldsNothing() {
    let missing = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("corvo-tests-\(UUID().uuidString)/Gone.app")

    #expect(AppChooser.bundleId(forApplicationAt: missing) == nil)
}

// MARK: - The picker's list

private let slack = SourceSummary(bundleId: "com.tinyspeck.slackmacgap", name: "Slack", count: 4)

@Test @MainActor func withNothingChosenTheListIsWhatTheHistoryHasSeen() {
    #expect(AppChooser.choices(seen: [slack], selected: nil) == [slack])
}

@Test @MainActor func anAppTheHistoryHasSeenIsNotListedTwice() {
    #expect(AppChooser.choices(seen: [slack], selected: slack.bundleId) == [slack])
}

/// The case the panel creates: a rule for an app nothing has been copied from
/// yet. Without this row the picker holds a value its own menu does not offer.
@Test @MainActor func anAppOutsideTheHistoryIsListedAnyway() {
    let choices = AppChooser.choices(seen: [slack], selected: "com.wylp.not.installed")

    #expect(choices.count == 2)
    #expect(choices.last?.bundleId == "com.wylp.not.installed")
    // Nothing is installed under that id, so the id is all the name there is.
    #expect(choices.last?.name == "com.wylp.not.installed")
    #expect(choices.last?.count == 0)
}

/// The row a real chosen app produces: named, not spelled in reverse DNS.
@Test @MainActor func aChosenAppThatIsInstalledIsListedByName() throws {
    let finder = "com.apple.finder"
    try #require(AppChooser.name(forBundleId: finder) != nil)

    let choices = AppChooser.choices(seen: [], selected: finder)

    #expect(choices.map(\.name) == ["Finder"])
}
