import Foundation
import AppKit
import UserNotifications
import AitvarasCore
import AitvarasStore

/// Quiet, private-safe delivery. Routine updates remain inside the app;
/// explicitly enabled urgent updates may produce a generic system alert.
@MainActor
final class NotificationRouter {
    private let stores: Stores

    /// Embodied announcement — show Aitvaras, speak, caption. Set by the app.
    var announce: ((_ text: String) -> Void)?
    var reportError: ((_ title: String, _ error: Error) -> Void)?

    init(stores: Stores) {
        self.stores = stores
    }

    /// No permission request and no sensitive preview. Only a failure of work
    /// the user requested (or capture data-loss risk) calls this path.
    static func requestedWorkNeedsAttention() {
        guard !NSApplication.shared.isActive else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = "Aitvaras needs your attention"
            content.body = "A requested action could not finish. Open Aitvaras to review it."
            try? await center.add(UNNotificationRequest(identifier: "requested-work-needs-attention", content: content, trigger: nil))
        }
    }

    /// Non-urgent notifications hold while a Focus Session is running
    /// (single source of truth — was a separate "focus mode" flag).
    private func focusModeActive() throws -> Bool {
        try stores.value(forKey: FocusCoach.sessionKey) == "1"
    }

    /// Route a message. `urgent` bypasses the focus hold.
    func deliver(title: String, body: String, urgent: Bool = false) {
        if urgent {
            surface(title: title, body: body, urgent: urgent)
            return
        }
        do {
            let held = HeldNotification(title: title, body: body)
            try stores.holdNotification(held, recording: ActivityEvent(
                kind: .notificationSent, connectorID: "focus",
                summary: "Update available inside Aitvaras"))
        } catch {
            reportError?("Update could not be held for the next break", error)
            // Storage failure must degrade to immediate delivery, never loss.
            surface(title: title, body: body, urgent: false)
        }
    }

    /// Read without deleting: the caller may spend time composing a briefing.
    func heldItems() -> [HeldNotification] {
        do {
            return try stores.heldNotifications()
        } catch {
            reportError?("Held updates could not be loaded", error)
            return []
        }
    }

    func markDelivered(_ items: [HeldNotification]) {
        do {
            try stores.clearHeldNotifications(ids: items.map(\.id))
        } catch {
            // Retaining them can duplicate a later briefing, but cannot lose it.
            reportError?("Delivered updates could not be cleared", error)
        }
    }

    /// Compatibility hook for old break/wake paths. Held updates stay available
    /// in Home until reviewed; a wake must not requeue, speak or discard them.
    func flushHeld(reason: String) {
        NotificationCenter.default.post(name: .aitvarasActivityChanged, object: nil)
    }

    /// Public surface: present → embodied (speak + caption), away → macOS.
    func speakOrPost(title: String, body: String, urgent: Bool) {
        surface(title: title, body: body, urgent: urgent)
    }

    /// Present → embodied (Aitvaras appears + speaks + caption). Away → a
    /// macOS notification, since the on-screen overlay would be missed.
    private func surface(title: String, body: String, urgent: Bool) {
        // Background progress never expands the companion or starts speech.
        let held = HeldNotification(title: title, body: body)
        try? stores.holdNotification(held, recording: ActivityEvent(
            kind: .notificationQueued, connectorID: "local",
            summary: urgent ? "An urgent update needs review" : "An update is available"))
        NotificationCenter.default.post(name: .aitvarasActivityChanged, object: nil)
        if urgent, !NSApplication.shared.isActive { post(title: "Aitvaras needs your attention", body: "Open Aitvaras to review an urgent update.", sound: true) }
    }

    private func post(title: String, body: String, sound urgent: Bool) {
        let content = UNMutableNotificationContent()
        content.title = "Aitvaras needs your attention"
        content.body = "Open Aitvaras to review an update."
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
