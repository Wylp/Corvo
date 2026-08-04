import Foundation
import Testing
@testable import Corvo

private let slack = ItemSource(bundleId: "com.tinyspeck.slackmacgap", name: "Slack")
private let terminal = ItemSource(bundleId: "com.apple.Terminal", name: "Terminal")
private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

@Test @MainActor func withNoRecordedActivationThereIsNoSource() {
    let tracker = SourceTracker()
    #expect(tracker.captureSource(at: t0) == nil)
}

@Test @MainActor func aRecentSwitchCreditsThePreviousApp() {
    let tracker = SourceTracker(switchWindow: 0.3)
    tracker.recordActivation(slack, at: t0)
    tracker.recordActivation(terminal, at: t0.addingTimeInterval(1))

    // Copied in Slack and switched to Terminal 0.1s before the poll.
    let source = tracker.captureSource(at: t0.addingTimeInterval(1.1))

    #expect(source == slack)
}

@Test @MainActor func anOldSwitchCreditsTheCurrentApp() {
    let tracker = SourceTracker(switchWindow: 0.3)
    tracker.recordActivation(slack, at: t0)
    tracker.recordActivation(terminal, at: t0.addingTimeInterval(1))

    let source = tracker.captureSource(at: t0.addingTimeInterval(5))

    #expect(source == terminal)
}

@Test @MainActor func withNoPreviousAppARecentSwitchCreditsTheCurrentOne() {
    let tracker = SourceTracker(switchWindow: 0.3)
    tracker.recordActivation(slack, at: t0)

    #expect(tracker.captureSource(at: t0.addingTimeInterval(0.1)) == slack)
}
