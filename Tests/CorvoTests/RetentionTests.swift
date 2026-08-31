import Foundation
import Testing
@testable import Corvo

private let now = Date(timeIntervalSince1970: 1_700_000_000)

private func makeEnvironment() throws -> (ItemRepository, BlobStore, Retention, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("corvo-ret-\(UUID().uuidString)")
    let blobs = BlobStore(directory: dir)
    let repo = ItemRepository(dbQueue: try AppDatabase.make(at: nil), blobs: blobs)
    return (repo, blobs, Retention(repo: repo, blobs: blobs), dir)
}

private func textItem(_ s: String) -> CapturedItem {
    CapturedItem(kind: .text, text: s, imageData: nil,
                 filePath: nil, url: nil, contentHash: s)
}

@Test func ageBasedPruneRemovesOldItems() throws {
    let (repo, _, retention, dir) = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: dir) }

    try repo.insert(textItem("old"), source: nil, now: now.addingTimeInterval(-40 * 86400))
    try repo.insert(textItem("new"), source: nil, now: now)

    let removed = try retention.prune(policy: .standard, now: now)

    #expect(removed == 1)
    let remaining = try repo.search(text: "", sourceBundleId: nil, tagId: nil, limit: 50)
    #expect(remaining.map(\.text) == ["new"])
}

@Test func pinnedAndTaggedItemsNeverExpire() throws {
    let (repo, _, retention, dir) = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: dir) }

    let oldDate = now.addingTimeInterval(-40 * 86400)
    let pinned = try repo.insert(textItem("pinned"), source: nil, now: oldDate)
    let tagged = try repo.insert(textItem("tagged"), source: nil, now: oldDate)
    try repo.insert(textItem("disposable"), source: nil, now: oldDate)
    try repo.setPinned(pinned, true)
    try repo.addTag(named: "keep", to: tagged)

    let removed = try retention.prune(policy: .standard, now: now)

    #expect(removed == 1)
    let remaining = try repo.search(text: "", sourceBundleId: nil, tagId: nil, limit: 50)
    #expect(Set(remaining.compactMap(\.text)) == ["pinned", "tagged"])
}

@Test func countBasedPruneDoesNotCountProtectedItems() throws {
    let (repo, _, retention, dir) = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: dir) }

    let pinned = try repo.insert(textItem("pinned"), source: nil, now: now)
    try repo.setPinned(pinned, true)
    for i in 0..<5 {
        try repo.insert(textItem("item \(i)"), source: nil,
                        now: now.addingTimeInterval(Double(i)))
    }

    let policy = RetentionPolicy(maxItems: 3, maxAge: nil)
    let removed = try retention.prune(policy: policy, now: now)

    // 5 unprotected, ceiling 3 → removes the 2 oldest. The pinned one stays.
    #expect(removed == 2)
    let remaining = try repo.search(text: "", sourceBundleId: nil, tagId: nil, limit: 50)
    #expect(remaining.count == 4)
}

@Test func pruneDeletesBlobsThatBecameOrphans() throws {
    let (repo, blobs, retention, dir) = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: dir) }

    let png = Data([0x89, 0x50])
    try repo.insert(CapturedItem(kind: .image, text: "img", imageData: png,
                                 filePath: nil, url: nil, contentHash: "old"),
                    source: nil, now: now.addingTimeInterval(-40 * 86400))

    #expect(FileManager.default.fileExists(atPath: blobs.url(for: "old.png").path))

    try retention.prune(policy: .standard, now: now)

    #expect(!FileManager.default.fileExists(atPath: blobs.url(for: "old.png").path))
}

private func contents(_ repo: ItemRepository) throws -> Set<String> {
    Set(try repo.search(text: "", sourceBundleId: nil, tagId: nil, limit: 500)
        .compactMap(\.text))
}

/// The protection clause appears in TWO separate DELETEs. `pinnedAndTaggedItemsNeverExpire`
/// only exercises the age path, and `countBasedPruneDoesNotCountProtectedItems` only uses a
/// pinned item — nothing covered tags on the count path. A missing EXISTS there would
/// silently delete items the user marked to keep.
@Test func tagAlsoProtectsOnTheCountBasedPrune() throws {
    let (repo, _, retention, dir) = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: dir) }

    for i in 0..<5 {
        let id = try repo.insert(textItem("tagged\(i)"), source: nil,
                                 now: now.addingTimeInterval(Double(i)))
        try repo.addTag(named: "keep", to: id)
    }
    for i in 0..<3 {
        try repo.insert(textItem("untagged\(i)"), source: nil,
                        now: now.addingTimeInterval(Double(100 + i)))
    }

    let removed = try retention.prune(
        policy: RetentionPolicy(maxItems: 2, maxAge: nil),
        now: now.addingTimeInterval(1000))

    #expect(removed == 1)
    #expect(try contents(repo) == ["tagged0", "tagged1", "tagged2", "tagged3",
                                   "tagged4", "untagged1", "untagged2"])
}

/// `LIMIT -1 OFFSET ?` skips the N newest and deletes the rest. Swapping it for `LIMIT ?`
/// would invert the behaviour while keeping the SAME survivor count — which is why this
/// test checks which items survived by content, not by total.
@Test func countBasedPruneDeletesTheOldestNotTheNewest() throws {
    let (repo, _, retention, dir) = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: dir) }

    for i in 0..<5 {
        try repo.insert(textItem("i\(i)"), source: nil,
                        now: now.addingTimeInterval(Double(i)))
    }

    let removed = try retention.prune(
        policy: RetentionPolicy(maxItems: 2, maxAge: nil),
        now: now.addingTimeInterval(1000))

    #expect(removed == 3)
    #expect(try contents(repo) == ["i3", "i4"])
}

// MARK: - The sweep that runs on every capture

@Test func theCeilingSweepKeepsTheNewestAndDeletesTheRest() throws {
    let (repo, _, retention, dir) = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: dir) }

    for i in 0..<5 {
        try repo.insert(textItem("i\(i)"), source: nil, now: now.addingTimeInterval(Double(i)))
    }

    let removed = try retention.enforceItemCeiling(policy: RetentionPolicy(maxItems: 2, maxAge: nil))

    #expect(removed == 3)
    #expect(try contents(repo) == ["i3", "i4"])
}

/// It is the count rule and nothing else. An expired clipping is left for the
/// full prune, so the copy path never pays for the age sweep.
@Test func theCeilingSweepLeavesExpiredItemsAlone() throws {
    let (repo, _, retention, dir) = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: dir) }

    try repo.insert(textItem("ancient"), source: nil, now: now.addingTimeInterval(-400 * 86400))
    try repo.insert(textItem("fresh"), source: nil, now: now)

    let removed = try retention.enforceItemCeiling(policy: .standard)

    #expect(removed == 0)
    #expect(try contents(repo) == ["ancient", "fresh"])
}

@Test func theCeilingSweepDoesNothingWithNoCeiling() throws {
    let (repo, _, retention, dir) = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: dir) }

    for i in 0..<4 {
        try repo.insert(textItem("i\(i)"), source: nil, now: now.addingTimeInterval(Double(i)))
    }

    #expect(try retention.enforceItemCeiling(policy: RetentionPolicy(maxItems: nil, maxAge: nil)) == 0)
    #expect(try contents(repo).count == 4)
}

/// The deliberate deferral, tested so it cannot be "fixed" into existence: the
/// capture path skips the blob collection because that walks the whole blob
/// directory on the main thread. The orphan waits for the next full prune.
@Test func theCeilingSweepLeavesTheBlobForTheNextFullPrune() throws {
    let (repo, blobs, retention, dir) = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: dir) }

    try repo.insert(CapturedItem(kind: .image, text: "img", imageData: Data([0x89, 0x50]),
                                 filePath: nil, url: nil, contentHash: "doomed"),
                    source: nil, now: now)
    try repo.insert(textItem("newer"), source: nil, now: now.addingTimeInterval(1))

    #expect(try retention.enforceItemCeiling(policy: RetentionPolicy(maxItems: 1, maxAge: nil)) == 1)
    // The row is gone and the file is not.
    #expect(try contents(repo) == ["newer"])
    #expect(FileManager.default.fileExists(atPath: blobs.url(for: "doomed.png").path))

    try retention.prune(policy: RetentionPolicy(maxItems: 1, maxAge: nil), now: now)
    #expect(!FileManager.default.fileExists(atPath: blobs.url(for: "doomed.png").path))
}

@Test func theCeilingSweepProtectsPinnedAndTaggedItems() throws {
    let (repo, _, retention, dir) = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: dir) }

    let pinned = try repo.insert(textItem("pinned"), source: nil, now: now)
    let tagged = try repo.insert(textItem("tagged"), source: nil, now: now.addingTimeInterval(1))
    try repo.setPinned(pinned, true)
    try repo.addTag(named: "keep", to: tagged)
    for i in 0..<3 {
        try repo.insert(textItem("spare\(i)"), source: nil,
                        now: now.addingTimeInterval(Double(10 + i)))
    }

    try retention.enforceItemCeiling(policy: RetentionPolicy(maxItems: 1, maxAge: nil))

    let survivors = try contents(repo)
    #expect(survivors.contains("pinned"))
    #expect(survivors.contains("tagged"))
    #expect(survivors.count == 3)
}

// MARK: - A rule that is switched off

/// Six rows, no ceiling. The count sweep must not run at all — not with a large
/// number, not with the stored one, not at all.
@Test func withNoCeilingNothingIsDeletedForBeingNumerous() throws {
    let (repo, _, retention, dir) = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: dir) }

    for i in 0..<6 {
        try repo.insert(textItem("i\(i)"), source: nil, now: now.addingTimeInterval(Double(i)))
    }

    let removed = try retention.prune(policy: RetentionPolicy(maxItems: nil, maxAge: nil),
                                      now: now.addingTimeInterval(1000))

    #expect(removed == 0)
    #expect(try contents(repo).count == 6)
}

/// Ten years old with no expiry rule. This is the case a stored per-clipping TTL
/// would have got wrong: the age is compared at prune time, so a rule that is off
/// leaves the row alone however old `createdAt` says it is.
@Test func withNoExpiryNothingIsDeletedForBeingOld() throws {
    let (repo, _, retention, dir) = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: dir) }

    try repo.insert(textItem("ancient"), source: nil,
                    now: now.addingTimeInterval(-3650 * 86400))
    try repo.insert(textItem("recent"), source: nil, now: now)

    let removed = try retention.prune(policy: RetentionPolicy(maxItems: 100, maxAge: nil),
                                      now: now)

    #expect(removed == 0)
    #expect(try contents(repo) == ["ancient", "recent"])
}

/// Both rules off. Nothing is deleted for any reason — and the blob collection
/// still runs, because it answers to the rows that exist rather than to a policy.
@Test func withBothRulesOffTheHistoryOnlyGrows() throws {
    let (repo, blobs, retention, dir) = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: dir) }

    let old = now.addingTimeInterval(-4000 * 86400)
    for i in 0..<4 {
        try repo.insert(textItem("keep\(i)"), source: nil, now: old.addingTimeInterval(Double(i)))
    }
    let id = try repo.insert(CapturedItem(kind: .image, text: "img", imageData: Data([0x89, 0x50]),
                                          filePath: nil, url: nil, contentHash: "orphan"),
                             source: nil, now: old)

    let removed = try retention.prune(policy: RetentionPolicy(maxItems: nil, maxAge: nil), now: now)
    #expect(removed == 0)
    #expect(FileManager.default.fileExists(atPath: blobs.url(for: "orphan.png").path))

    // Deleted by hand rather than by a rule: the collection is not conditional on
    // anything having been pruned, and switching both rules off must not switch it
    // off as a side effect.
    try repo.delete(id)
    try retention.prune(policy: RetentionPolicy(maxItems: nil, maxAge: nil), now: now)
    #expect(!FileManager.default.fileExists(atPath: blobs.url(for: "orphan.png").path))
}

/// The protection is the user saying "keep this", so it cannot be quietly tied to
/// which rule happens to be on.
@Test func pinnedAndTaggedSurviveInAllFourStates() throws {
    let states = [RetentionPolicy(maxItems: 1, maxAge: 30 * 86400),
                  RetentionPolicy(maxItems: 1, maxAge: nil),
                  RetentionPolicy(maxItems: nil, maxAge: 30 * 86400),
                  RetentionPolicy(maxItems: nil, maxAge: nil)]

    for policy in states {
        let (repo, _, retention, dir) = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: dir) }

        let old = now.addingTimeInterval(-40 * 86400)
        let pinned = try repo.insert(textItem("pinned"), source: nil, now: old)
        let tagged = try repo.insert(textItem("tagged"), source: nil, now: old)
        try repo.setPinned(pinned, true)
        try repo.addTag(named: "keep", to: tagged)
        for i in 0..<3 {
            try repo.insert(textItem("spare\(i)"), source: nil, now: old.addingTimeInterval(Double(i)))
        }

        try retention.prune(policy: policy, now: now)

        let survivors = try contents(repo)
        #expect(survivors.contains("pinned"), "pinned lost with \(policy)")
        #expect(survivors.contains("tagged"), "tagged lost with \(policy)")
    }
}

/// Both policies biting at once: the returned count must not add the same item twice
/// across the two DELETEs.
@Test func ageAndCountPruneTogetherWithoutDoubleCounting() throws {
    let (repo, _, retention, dir) = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: dir) }

    let today = now.addingTimeInterval(1000)
    try repo.insert(textItem("old0"), source: nil, now: today.addingTimeInterval(-40 * 86400))
    try repo.insert(textItem("old1"), source: nil, now: today.addingTimeInterval(-35 * 86400))
    for i in 0..<4 {
        try repo.insert(textItem("new\(i)"), source: nil,
                        now: today.addingTimeInterval(Double(i) - 100))
    }
    let protected = try repo.insert(textItem("oldTagged"), source: nil,
                                    now: today.addingTimeInterval(-50 * 86400))
    try repo.addTag(named: "keep", to: protected)

    let before = try contents(repo).count
    let removed = try retention.prune(
        policy: RetentionPolicy(maxItems: 2, maxAge: 30 * 86400), now: today)
    let after = try contents(repo)

    #expect(removed == before - after.count)
    #expect(removed == 4)
    #expect(after == ["oldTagged", "new2", "new3"])
}

/// A name protects a clipping the way a tag already did. Both take a
/// deliberate keystroke and a sentence typed on purpose; only one of them
/// used to survive the prune.
@Test func namedItemsNeverExpireEither() throws {
    let (repo, _, retention, dir) = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: dir) }

    let oldDate = now.addingTimeInterval(-40 * 86400)
    let named = try repo.insert(textItem("named"), source: nil, now: oldDate)
    let unnamed = try repo.insert(textItem("unnamed"), source: nil, now: oldDate)
    try repo.setLabel("the server password", for: named)
    // Clearing a name is the way back out, so it must not go on protecting.
    try repo.setLabel("", for: unnamed)

    let removed = try retention.prune(policy: .standard, now: now)

    #expect(removed == 1)
    let remaining = try repo.search(text: "", sourceBundleId: nil, tagId: nil, limit: 50)
    #expect(remaining.compactMap(\.text) == ["named"])
}

/// And it does not count towards the ceiling either, which is the half that
/// would otherwise push the unnamed clippings out one name at a time.
@Test func namedItemsDoNotCountTowardsTheCeiling() throws {
    let (repo, _, retention, dir) = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: dir) }

    let named = try repo.insert(textItem("named"), source: nil, now: now)
    try repo.setLabel("keep me", for: named)
    for i in 0..<3 {
        try repo.insert(textItem("item \(i)"), source: nil,
                        now: now.addingTimeInterval(Double(i) + 1))
    }

    // Room for two unnamed clippings; the named one is not one of them.
    try retention.prune(policy: RetentionPolicy(maxItems: 2, maxAge: .infinity), now: now)

    let remaining = try repo.search(text: "", sourceBundleId: nil, tagId: nil, limit: 50)
    #expect(Set(remaining.compactMap(\.text)) == ["named", "item 2", "item 1"])
}
