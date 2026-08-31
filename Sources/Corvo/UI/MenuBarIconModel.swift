import Combine
import Foundation

/// The state behind the "Show icon in menu bar" row.
///
/// It is a model rather than a `Binding` over `Preferences` because the row has
/// to see writes it did not make, and `Preferences` is a typed view onto
/// `UserDefaults` that announces nothing. Reading it straight from the body was
/// the first version and it was wrong in a way worth writing down: switching the
/// icon *on* stored `true` and changed no `@State`, so nothing invalidated the
/// view — the row went on drawing the value the last body pass had read, showing
/// a switch that was off over a setting that was on, and it stayed wrong when the
/// window was closed and opened because that does not re-evaluate a body either.
/// Only the hide looked right, and only by accident: it flips `isConfirmingHide`,
/// and that is what recomputed the body.
///
/// Two writers share this setting, which is the second reason. `MenuBarExtra`'s
/// `isInserted` is bound to the same key, so ⌘-dragging the icon out of the menu
/// bar stores `false` without this screen being involved at all. Observing the
/// store is what lets one switch answer for both.
@MainActor
final class MenuBarIconModel: ObservableObject {
    private let prefs: Preferences
    /// Both `nonisolated` so `deinit`, which is not, can hand the observer back.
    /// A block observer outlives the object that registered it, and the Settings
    /// window builds one of these per launch — but the tests build many.
    private nonisolated let notifications: NotificationCenter
    private nonisolated(unsafe) var observer: (any NSObjectProtocol)?

    /// Whether the icon is in the menu bar. Written through `Preferences`, and
    /// re-read from it whenever anything in the store changes, so it is never a
    /// copy that can drift — only ever the last thing anyone stored.
    @Published private(set) var isShown: Bool

    /// Drives the confirmation. Hiding takes the app's only visible control away,
    /// so it is asked about; showing is not.
    @Published var isConfirmingHide = false

    /// - Parameter notifications: where `UserDefaults.didChangeNotification`
    ///   is listened for. The default is the only value the app ever passes. It
    ///   is a parameter so a test can hand over a centre nothing posts to, which
    ///   is what separates the two ways this value moves: hearing a write made
    ///   elsewhere, and publishing one made here. Sharing one centre lets either
    ///   mechanism cover for the other's absence, and a bug that only shows up
    ///   when both are broken is a bug no test can hold down.
    init(prefs: Preferences, notifications: NotificationCenter = .default) {
        self.prefs = prefs
        self.notifications = notifications
        isShown = prefs.showsMenuBarIcon

        // No `object:` filter. The store this reads is the one `Preferences` was
        // built with, which the model has no handle on — and a needless re-read
        // when some other suite changes costs one `object(forKey:)`, while a
        // missed one is the bug above.
        observer = notifications.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil,
            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Assigning unconditionally would publish on every unrelated
                // defaults write in the process.
                let stored = self.prefs.showsMenuBarIcon
                guard stored != self.isShown else { return }
                self.isShown = stored
            }
        }
    }

    deinit {
        guard let observer else { return }
        notifications.removeObserver(observer)
    }

    /// The switch moved. Showing is immediate — an icon appearing needs no
    /// warning — and hiding only raises the confirmation. Nothing is stored on
    /// the way to that alert, so a cancelled hide leaves nothing to undo.
    func request(_ shown: Bool) {
        guard shown else {
            isConfirmingHide = true
            return
        }
        store(true)
    }

    /// The Hide button. This is the only place the icon is taken away.
    func confirmHide() { store(false) }

    private func store(_ shown: Bool) {
        prefs.showsMenuBarIcon = shown
        // Set here as well as in the observer: the notification is what covers a
        // write made anywhere else, and this is what makes our own write visible
        // even if it never arrives.
        isShown = shown
    }
}
