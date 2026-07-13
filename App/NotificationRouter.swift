import Foundation
import UserNotifications
import AitvarasCore
import AitvarasStore

/// Single gate for every proactive thing Aitvaras says (mail triage,
/// trigger events, focus nudges, break reminders). When the user is at
/// the Mac, Aitvaras APPEARS and SPEAKS with a visible caption (embodied,
/// not a system notification). Only when the user is away does this fall
/// back to a macOS notification. Focus mode holds non-urgent updates
/// until the next break; urgent items punch through immediately.
@MainActor
final class NotificationRouter {
    private let stores: Stores
    private struct Held { let title: String; let body: String; let at: Date }
    private var held: [Held] = []

    /// Embodied announcement — show Aitvaras, speak, caption. Set by the app.
    var announce: ((_ text: String) -> Void)?

    init(stores: Stores) {
        self.stores = stores
    }

    /// Non-urgent notifications hold while a Focus Session is running
    /// (single source of truth — was a separate "focus mode" flag).
    var focusModeActive: Bool {
        (try? stores.value(forKey: FocusCoach.sessionKey)) == "1"
    }

    /// Route a message. `urgent` bypasses the focus hold.
    func deliver(title: String, body: String, urgent: Bool = false) {
        if urgent || !focusModeActive {
            surface(title: title, body: body, urgent: urgent)
        } else {
            held.append(Held(title: title, body: body, at: .now))
            try? stores.record(ActivityEvent(
                kind: .notificationSent, connectorID: "focus",
                summary: "Held for break: \(title)"))
        }
    }

    /// Remove and return held items (the caller composes a briefing).
    func takeHeld() -> [(title: String, body: String)] {
        let items = held.map { ($0.title, $0.body) }
        held.removeAll()
        return items
    }

    var heldCount: Int { held.count }

    /// Deliver everything held back — simple fallback path.
    func flushHeld(reason: String) {
        let items = takeHeld()
        guard !items.isEmpty else { return }
        if items.count == 1, let item = items.first {
            surface(title: item.title, body: item.body, urgent: false)
        } else {
            let lines = items.map { "\($0.title): \($0.body)" }.joined(separator: ". ")
            surface(title: "\(items.count) updates while you were focused", body: lines, urgent: false)
        }
    }

    /// Public surface: present → embodied (speak + caption), away → macOS.
    func speakOrPost(title: String, body: String, urgent: Bool) {
        surface(title: title, body: body, urgent: urgent)
    }

    /// Present → embodied (Aitvaras appears + speaks + caption). Away → a
    /// macOS notification, since the on-screen overlay would be missed.
    private func surface(title: String, body: String, urgent: Bool) {
        let present = !IntegrationCoordinator.userIsAway()
        if present, let announce {
            announce(body.isEmpty ? title : "\(title). \(body)")
        } else {
            post(title: title, body: body, sound: urgent)
        }
    }

    private func post(title: String, body: String, sound urgent: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(body.prefix(600))
        if urgent {
            content.sound = .default
            // The intended workflow is: user turns on a macOS Focus to
            // mute app banners; Aitvaras reads the suppressed ones and
            // re-surfaces only the urgent. Time-sensitive lets HER alert
            // pierce that same Focus (user must still allow time-sensitive
            // for Aitvaras, or add her to the Focus's allowed apps).
            content.interruptionLevel = .timeSensitive
        }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
