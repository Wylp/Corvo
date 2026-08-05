import Foundation
import UserNotifications

/// Asks the user what to call a clipping a rule just claimed, in a notification
/// carrying its own text field. No window opens and nothing takes focus: the
/// answer is typed into the banner, or the banner is ignored.
///
/// Ignoring it costs nothing. By the time this runs the clipping is stored and
/// tagged, and the panel marks it as still unnamed either way — so a notification
/// that is missed, dismissed, or never authorized at all loses no work and no
/// content. That is the whole reason this is a notification and not a modal: a
/// window stealing focus on every match turns a slightly-too-wide rule into an
/// interruption the user cannot escape.
@MainActor
final class NamePrompt: NSObject, UNUserNotificationCenterDelegate {
    /// The name the user typed, with the item it belongs to. Set by the app
    /// delegate, which owns the model that writes it.
    var onName: ((Int64, String) -> Void)?
    /// The banner itself was clicked rather than answered. Shows the panel.
    var onOpen: (() -> Void)?

    private let center = UNUserNotificationCenter.current()

    private nonisolated static let categoryId = "corvo.name"
    private nonisolated static let actionId = "corvo.name.text"

    /// One identifier for every prompt, deliberately. Ten matches in twenty
    /// seconds arrive as one notification showing the most recent, not ten
    /// stacked in Notification Center — a rule a little too wide would
    /// otherwise punish the user for having written it. The clippings whose
    /// prompt got replaced are not lost: each one is stored, tagged, and
    /// carries "Name this" on its card until it has a name.
    ///
    /// ponytail: latest wins, with no memory of what it replaced. The ceiling
    /// is that a burst is nameable one clipping deep from the banner and the
    /// rest only from the panel. Upgrade, if that turns out to bite: a queue
    /// that re-posts the next unnamed one after each answer.
    private nonisolated static let requestId = "corvo.name.request"

    /// `nil` until we have asked once. Cached so a refusal is a single dialog
    /// per launch instead of one per matching copy.
    private var granted: Bool?

    override init() {
        super.init()
        // Neither of these shows the user anything. The dialog comes from
        // `requestAuthorization`, and that waits until there is something to
        // ask about — see `authorize()`.
        center.delegate = self
        center.setNotificationCategories([Self.category])
    }

    /// ponytail: how much of this the user actually sees is theirs to decide,
    /// not ours. macOS gives a new app the "Banner" alert style, which fades
    /// after a few seconds; the text field is one hover away on the banner and
    /// always there in Notification Center, but a user who blinks has to go
    /// looking. There is no API to force the "Alert" style — `.timeSensitive`
    /// needs an entitlement Corvo does not have and would not deserve. The
    /// panel's ⌘R is the answer to a missed banner, and the reason this is not
    /// worth fighting the system over.
    private static var category: UNNotificationCategory {
        let action = UNTextInputNotificationAction(
            identifier: actionId,
            title: String(localized: "Name it"),
            options: [],
            textInputButtonTitle: String(localized: "Save"),
            textInputPlaceholder: String(localized: "What is this?"))
        return UNNotificationCategory(identifier: categoryId, actions: [action],
                                      intentIdentifiers: [], options: [])
    }

    /// Fire-and-forget: called from `PasteboardMonitor.poll`, which is the
    /// capture path and must not wait on — or fail because of — a notification.
    func ask(toName itemId: Int64, tag: String, preview: String?) {
        Task {
            guard await authorize() else { return }
            await Self.post(itemId: itemId, tag: tag, preview: preview)
        }
    }

    /// `nonisolated` and `static`, and the centre is fetched inside rather than
    /// read off `self`: `UNUserNotificationCenter` is not `Sendable`, so a
    /// main-actor method awaiting on a stored one is sending it across an
    /// isolation boundary. Everything that crosses into here is a value.
    private nonisolated static func post(itemId: Int64, tag: String,
                                         preview: String?) async {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Name this clipping")
        // Which rule spoke. Without it the user gets a question with no visible
        // cause, and the answer to "why is it asking me this" is a tag they
        // configured themselves.
        content.subtitle = String(localized: "Tagged \(tag)")
        content.body = Self.oneLine(preview)
        content.categoryIdentifier = categoryId
        content.userInfo = ["itemId": itemId]

        do {
            try await UNUserNotificationCenter.current()
                .add(UNNotificationRequest(identifier: requestId,
                                           content: content, trigger: nil))
        } catch {
            NSLog("Corvo: could not post the name prompt: \(error)")
        }
    }

    /// Asked at the first capture a rule wants named, never at launch: a
    /// permission dialog with no reason attached is how an app earns a "no".
    ///
    /// A denial is not an error path to recover from — `ask` simply stops
    /// posting, and naming stays where it already was, on ⌘R in the panel.
    private func authorize() async -> Bool {
        if let granted { return granted }
        let ok = await Self.request()
        granted = ok
        if !ok {
            NSLog("Corvo: notifications are not authorized — naming stays on ⌘R in the panel.")
        }
        return ok
    }

    /// Alert only. No sound and no badge: this is a question that can wait, and
    /// it should interrupt nothing that is not already on screen.
    private nonisolated static func request() async -> Bool {
        (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert])) ?? false
    }

    /// The body is the clipping itself, which is what the user is being asked
    /// about. Flattened to one line and cut short, because a banner shows two
    /// at most and a wrapped 4KB paste would show none of them.
    private nonisolated static func oneLine(_ text: String?) -> String {
        let flat = (text ?? "").split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard flat.count > 120 else { return flat }
        return flat.prefix(119) + "…"
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Corvo is an agent app, but its own panel can be frontmost at the moment a
    /// copy lands. Without this the banner is swallowed exactly then.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }

    /// The completion-handler form rather than the `async` one on purpose:
    /// `UNNotificationResponse` is not `Sendable`, so it stays on this thread
    /// and only the id and the typed name cross to the main actor.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }

        let userInfo = response.notification.request.content.userInfo
        if let typed = response as? UNTextInputNotificationResponse,
           let id = (userInfo["itemId"] as? NSNumber)?.int64Value {
            let name = typed.userText
            Task { @MainActor in self.onName?(id, name) }
            return
        }

        // Clicked, not answered. Dismissing is not clicking, so it falls
        // through here and does nothing, which is what dismissing means.
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        Task { @MainActor in self.onOpen?() }
    }
}
