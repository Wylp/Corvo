import Testing
@testable import Corvo

/// Adding and removing an entry, now that the pane is a list rather than a
/// field of text.
///
/// These were two lines inside the view until the pane changed shape. They are
/// out here because the change came with a reminder of what that costs: the
/// write that stored the blocklist hung off the `TextEditor`, and deleting that
/// control deleted the write with it — unblocking an app would have looked
/// right and stored nothing.

@Test func addingAppendsInOrder() {
    let text = Blocklist.adding("com.b.two", to: "com.a.one")
    #expect(Blocklist.entries(text) == ["com.a.one", "com.b.two"])
}

@Test func addingToNothingStarts() {
    #expect(Blocklist.entries(Blocklist.adding("com.a.one", to: "")) == ["com.a.one"])
}

/// The app is already blocked, so there is nothing to fix and nothing changed.
@Test func addingSomethingAlreadyThereChangesNothing() {
    let text = "com.a.one\ncom.b.two"
    #expect(Blocklist.adding("com.a.one", to: text) == text)
    #expect(Blocklist.adding("com.b.two", to: text) == text)
}

/// Stored even when it cannot match an app, which is the rule `entries` already
/// documents: a typo dropped on the way in disappears from the screen and
/// leaves the user believing an app is blocked.
@Test func addingSomethingThatIsNotABundleIdStillStoresIt() {
    let text = Blocklist.adding("not a bundle id", to: "")
    #expect(Blocklist.entries(text) == ["not a bundle id"])
    #expect(!Blocklist.isValidBundleId("not a bundle id"))
}

@Test func removingTakesOnlyThatOne() {
    let text = Blocklist.removing("com.b.two", from: "com.a.one\ncom.b.two\ncom.c.three")
    #expect(Blocklist.entries(text) == ["com.a.one", "com.c.three"])
}

/// The row it belonged to is already gone, so this is not an error.
@Test func removingSomethingAbsentChangesNothing() {
    let text = "com.a.one\ncom.b.two"
    #expect(Blocklist.entries(Blocklist.removing("com.z.nine", from: text))
            == ["com.a.one", "com.b.two"])
}

@Test func removingTheLastOneEmptiesIt() {
    #expect(Blocklist.entries(Blocklist.removing("com.a.one", from: "com.a.one")).isEmpty)
}

/// Order is what the user put things in, and it is what the list draws. A round
/// trip that reordered would move rows under the pointer.
@Test func theOrderSurvivesARoundTrip() {
    var text = ""
    for id in ["com.c.three", "com.a.one", "com.b.two"] {
        text = Blocklist.adding(id, to: text)
    }
    text = Blocklist.removing("com.a.one", from: text)
    text = Blocklist.adding("com.a.one", to: text)
    #expect(Blocklist.entries(text) == ["com.c.three", "com.b.two", "com.a.one"])
}
