import Foundation
import Testing
@testable import Corvo

/// A fake tree, so the two halves of the detection can be asked about
/// separately. Both matter, and the failure of the weaker version is not a
/// crash: `brew` existing without this cask means running `upgrade --cask`
/// against an install Homebrew does not manage, which either fails or puts a
/// second Corvo beside the one the user actually launched.
private final class FakeFileSystem: FileManager {
    var executables: Set<String> = []
    var files: Set<String> = []

    override func isExecutableFile(atPath path: String) -> Bool {
        executables.contains(path)
    }

    override func fileExists(atPath path: String) -> Bool {
        files.contains(path)
    }
}

@Test func brewIsFoundWhenItAlsoManagesThisCask() {
    let fs = FakeFileSystem()
    fs.executables = ["/opt/homebrew/bin/brew"]
    fs.files = ["/opt/homebrew/Caskroom/corvo"]
    #expect(UpdateInstaller.brewManagingCorvo(fileSystem: fs) == "/opt/homebrew/bin/brew")
}

/// Homebrew installed, Corvo not installed through it — a zip in Applications
/// beside a Homebrew the user has for other things. There is no upgrade to run.
@Test func brewWithoutTheCaskIsNotAnUpgradePath() {
    let fs = FakeFileSystem()
    fs.executables = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
    fs.files = []
    #expect(UpdateInstaller.brewManagingCorvo(fileSystem: fs) == nil)
}

/// The Caskroom without the binary. Left over from a Homebrew that was removed,
/// which is a state a machine can genuinely be in.
@Test func aCaskroomWithoutBrewIsNotAnUpgradePath() {
    let fs = FakeFileSystem()
    fs.executables = []
    fs.files = ["/opt/homebrew/Caskroom/corvo"]
    #expect(UpdateInstaller.brewManagingCorvo(fileSystem: fs) == nil)
}

@Test func noHomebrewAtAllIsNotAnUpgradePath() {
    #expect(UpdateInstaller.brewManagingCorvo(fileSystem: FakeFileSystem()) == nil)
}

/// Intel prefix. Not a fallback in the sense of being worse — it is where
/// Homebrew lives on those machines, and a GUI app's `PATH` has neither, which
/// is why both are spelled out.
@Test func theIntelPrefixWorksToo() {
    let fs = FakeFileSystem()
    fs.executables = ["/usr/local/bin/brew"]
    fs.files = ["/usr/local/Caskroom/corvo"]
    #expect(UpdateInstaller.brewManagingCorvo(fileSystem: fs) == "/usr/local/bin/brew")
}

/// Both present: take the one whose Caskroom has the cask, not the first `brew`
/// on disk. A machine with both prefixes and the cask only under one of them
/// would otherwise be told to upgrade with the wrong Homebrew.
@Test func thePrefixWithTheCaskWins() {
    let fs = FakeFileSystem()
    fs.executables = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
    fs.files = ["/usr/local/Caskroom/corvo"]
    #expect(UpdateInstaller.brewManagingCorvo(fileSystem: fs) == "/usr/local/bin/brew")
}

// MARK: - The script

/// The three steps, in the order that makes the upgrade take effect. Corvo has
/// to be gone before its bundle is replaced — a `brew upgrade` over the running
/// app swaps the binary on disk and leaves the old process alive on the deleted
/// inode, which reports success and changes nothing the user can see.
@Test func theScriptQuitsThenUpgradesThenReopens() throws {
    let script = UpdateInstaller.script(brew: "/opt/homebrew/bin/brew")
    let quit = try #require(script.range(of: "osascript"))
    let upgrade = try #require(script.range(of: "upgrade --cask corvo"))
    let reopen = try #require(script.range(of: "open -b"))

    #expect(quit.lowerBound < upgrade.lowerBound, "the app must be gone before the swap")
    #expect(upgrade.lowerBound < reopen.lowerBound, "reopening before the upgrade lands is a no-op")
}

/// A refused quit does not abort the upgrade: Homebrew's own `uninstall quit:`
/// is the second attempt, and stopping here would leave a wedged app unable to
/// ever update.
@Test func aFailedQuitDoesNotStopTheUpgrade() {
    #expect(UpdateInstaller.script(brew: "/opt/homebrew/bin/brew").contains("|| true"))
}

/// The brew that was found is the brew that runs. Hardcoding a prefix here
/// would undo the detection above on an Intel machine.
@Test func theScriptRunsTheBrewItWasGiven() {
    let script = UpdateInstaller.script(brew: "/usr/local/bin/brew")
    #expect(script.contains("/usr/local/bin/brew upgrade --cask corvo"))
    #expect(!script.contains("/opt/homebrew"))
}

/// By bundle id rather than by name, so the reopen cannot land on some other
/// app called Corvo that happens to be earlier in the search order.
@Test func theScriptReopensByBundleIdentifier() {
    let script = UpdateInstaller.script(brew: "/opt/homebrew/bin/brew")
    #expect(script.contains("open -b com.wylp.corvo"))
    #expect(script.contains("quit app id \"com.wylp.corvo\""))
}
