import AppKit
import SwiftUI

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
        // updateValue, not `cache[bundleId] = icon`: on a dictionary of optionals
        // the subscript treats a nil value as "remove this key", so the miss the
        // comment above promises to store would never be stored.
        cache.updateValue(icon, forKey: bundleId)
        return icon
    }

    /// The 16pt row icon, the same one in the sidebar and in the tag editor's
    /// app picker. An app that is not installed still gets a row: a rule
    /// outlives the app it names, and a missing icon must not take the name
    /// down with it.
    @ViewBuilder
    static func view(forBundleId bundleId: String) -> some View {
        if let icon = image(forBundleId: bundleId) {
            Image(nsImage: resized(icon)).resizable().frame(width: side, height: side)
        } else {
            Image(systemName: "app.dashed").frame(width: side).foregroundStyle(.secondary)
        }
    }

    private static let side: CGFloat = 16

    /// The `NSImage`'s own size, not only the SwiftUI frame around it: a
    /// `Picker`'s rows become `NSMenuItem`s, and a menu item draws its image at
    /// the image's size. Left alone, a 32pt app icon overflows the row and the
    /// closed pop-up button both. A copy, because the cache hands the same
    /// instance to the cards, which draw it larger.
    private static func resized(_ icon: NSImage) -> NSImage {
        guard let copy = icon.copy() as? NSImage else { return icon }
        copy.size = NSSize(width: side, height: side)
        return copy
    }
}
