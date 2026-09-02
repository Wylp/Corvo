import Foundation
import Testing
@testable import Corvo

/// The comparison behind the update check.
///
/// It is a separate type with its own tests because the obvious implementation
/// is wrong in a way that hides: comparing the strings works for every release
/// this project has had so far and breaks at the tenth of any series, which is
/// exactly when nobody is looking at it any more.

@Test func aHigherComponentIsNewer() {
    #expect(AppVersion.isNewer("0.3.0", than: "0.2.0"))
    #expect(AppVersion.isNewer("1.0.0", than: "0.9.9"))
    #expect(AppVersion.isNewer("0.2.1", than: "0.2.0"))
}

/// The case string comparison gets backwards, and the reason this is not
/// `candidate > current`.
@Test func tenIsNewerThanTwo() {
    #expect(AppVersion.isNewer("0.10.0", than: "0.2.0"))
    #expect(!AppVersion.isNewer("0.2.0", than: "0.10.0"))
    #expect(AppVersion.isNewer("0.2.10", than: "0.2.9"))
}

@Test func theSameVersionIsNotNewer() {
    #expect(!AppVersion.isNewer("0.2.0", than: "0.2.0"))
}

@Test func anOlderVersionIsNotNewer() {
    #expect(!AppVersion.isNewer("0.1.0", than: "0.2.0"))
    #expect(!AppVersion.isNewer("0.2.0", than: "1.0.0"))
}

/// The tags are written `v0.2.0` and the API hands them back that way, so the
/// prefix has to survive the comparison rather than make it fail.
@Test func aLeadingVIsAccepted() {
    #expect(AppVersion.isNewer("v0.3.0", than: "0.2.0"))
    #expect(!AppVersion.isNewer("v0.2.0", than: "0.2.0"))
}

/// Missing components count as zero, so a two-part tag against a three-part
/// bundle version does not read as a release.
@Test func missingComponentsAreZero() {
    #expect(!AppVersion.isNewer("0.2", than: "0.2.0"))
    #expect(AppVersion.isNewer("0.3", than: "0.2.9"))
    #expect(AppVersion.isNewer("0.2.0.1", than: "0.2.0"))
}

/// Anything unparseable answers "not newer" rather than guessing. A phantom
/// update is the worse failure: it would claim a release that does not exist,
/// on every launch, with nothing to install.
@Test func garbageIsNotNewer() {
    #expect(!AppVersion.isNewer("banana", than: "0.2.0"))
    #expect(!AppVersion.isNewer("", than: "0.2.0"))
    #expect(!AppVersion.isNewer("v", than: "0.2.0"))
    #expect(!AppVersion.isNewer("0.2.0", than: "banana"))
    #expect(!AppVersion.isNewer("1.0", than: "not a version"))
}

/// A pre-release suffix does not parse, so it cannot announce itself. GitHub's
/// `releases/latest` already skips pre-releases; this is the second guard.
@Test func aPreReleaseSuffixIsNotNewer() {
    #expect(!AppVersion.isNewer("0.3.0-rc1", than: "0.2.0"))
    #expect(!AppVersion.isNewer("0.3.0b", than: "0.2.0"))
}

/// Negative numbers are not versions. Without the digit check `-1` parses as an
/// `Int` and "0.-1.0" would compare as though it meant something.
@Test func aNegativeComponentIsNotAVersion() {
    #expect(!AppVersion.isNewer("0.-1.0", than: "0.2.0"))
}

/// The endpoint excludes drafts and pre-releases, which is half of why the
/// parser above can afford to be strict. Pinned so a careless edit to `releases`
/// has to go through this.
@Test func theEndpointAsksForTheLatestRelease() {
    #expect(UpdateCheck.endpoint.absoluteString
        == "https://api.github.com/repos/Wylp/Corvo/releases/latest")
}

/// The bundle under test is the app, so this is the version the check compares
/// against — and a build that lost `CFBundleShortVersionString` would silently
/// compare against "0.0.0" and call every release an update.
@Test func theCurrentVersionComesFromTheBundle() throws {
    let version = AppVersion.current
    #expect(version != "0.0.0", "CFBundleShortVersionString is missing from the bundle")
    #expect(!AppVersion.isNewer(version, than: version))
}
