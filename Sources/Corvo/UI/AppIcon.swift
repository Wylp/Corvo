import AppKit

/// Icon of the source app, resolved by bundle ID. The carousel redraws on every
/// keystroke and on every poller write, so reading the icon off disk each frame
/// is waste — hence the cache.
@MainActor
enum AppIcon {
    /// Stores misses too: a bundle ID whose app was uninstalled is common in an
    /// old history, and without a negative entry it would hit the disk forever.
    ///
    /// ponytail: the cache never expires. Ceiling is an app that is installed,
    /// moved or re-themed while Corvo runs — it keeps the stale answer until the
    /// next launch. Upgrade path: clear it on
    /// `NSWorkspace.didLaunchApplicationNotification`.
    private static var cache: [String: NSImage?] = [:]

    static func image(forBundleId bundleId: String?) -> NSImage? {
        guard let bundleId else { return nil }
        if let cached = cache[bundleId] { return cached }
        let icon = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: bundleId)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[bundleId] = icon
        return icon
    }
}
