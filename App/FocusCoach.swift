import Foundation
import AppKit
import UserNotifications
import CoreGraphics
import AitvarasCore
import AitvarasStore
import AitvarasAgent

/// Owns the Focus Session — one coherent concept (was previously split
/// between a "coach" and a separate "focus mode"). While a session runs:
/// app usage is sampled locally, drift from today's goals is detected and
/// gently nudged, breaks are reminded on a configurable cadence, and
/// non-urgent notifications are held and delivered as a spoken briefing
/// at each break. Everything is local; app usage stays in memory.
@MainActor
final class FocusCoach {
    static let enabledKey = "focus.enabled"          // capability granted
    static let sessionKey = "focus.sessionActive"    // a session is running
    static let sessionStartKey = "focus.sessionStart"
    static let breakIntervalKey = "focus.breakIntervalMin"
    static let macFocusShortcutKey = "focus.macShortcut"   // optional auto-DND

    private let stores: Stores
    private let router: EngineRouter
    private let notifications: NotificationRouter

    private var samplerTask: Task<Void, Never>?
    private var driftTask: Task<Void, Never>?

    private struct Sample { let at: Date; let app: String }
    private var samples: [Sample] = []
    private var continuousActiveSince: Date?
    private var driftingSince: Date?
    private var lastBreakNudge: Date = .distantPast
    private var lastDriftNudge: Date = .distantPast
    private var sessionApps: [String: Int] = [:]     // whole-session app tally

    /// How responsive drift detection is, and how it's rate-limited.
    private let driftCheckInterval: TimeInterval = 4 * 60
    private let sustainedDriftBeforeNudge: TimeInterval = 5 * 60
    private let minGapBetweenDriftNudges: TimeInterval = 15 * 60

    init(stores: Stores, router: EngineRouter, notifications: NotificationRouter) {
        self.stores = stores
        self.router = router
        self.notifications = notifications
    }

    // MARK: Capability + session state

    var isEnabled: Bool {
        (try? stores.value(forKey: Self.enabledKey)) == "1"
    }

    var isSessionActive: Bool {
        (try? stores.value(forKey: Self.sessionKey)) == "1"
    }

    var sessionStart: Date? {
        guard let raw = try? stores.value(forKey: Self.sessionStartKey) ?? nil,
              let secs = Double(raw) else { return nil }
        return Date(timeIntervalSince1970: secs)
    }

    var breakIntervalMinutes: Int {
        Int((try? stores.value(forKey: Self.breakIntervalKey) ?? nil) ?? "") ?? 50
    }

    func setBreakInterval(minutes: Int) {
        try? stores.setValue(String(max(10, min(180, minutes))), forKey: Self.breakIntervalKey)
    }

    func setEnabled(_ enabled: Bool) {
        try? stores.setValue(enabled ? "1" : "0", forKey: Self.enabledKey)
        if enabled {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        } else {
            endSession()
        }
    }

    /// Resume a session that was active when the app last quit.
    func startIfSessionActive() {
        if isEnabled, isSessionActive { startMonitoring() }
    }

    /// Bring monitoring in line with the stored session flag — the flag
    /// can be flipped from voice/chat tools (which only write the store),
    /// so the app calls this after turns to start/stop the coach tasks.
    func reconcile() {
        if !isEnabled { stopMonitoring(); return }
        if isSessionActive, samplerTask == nil {
            sessionApps = [:]; lastBreakNudge = .now; lastDriftNudge = .distantPast; driftingSince = nil
            runMacFocusShortcut(on: true)
            startMonitoring()
            notifyStateChanged()
        } else if !isSessionActive, samplerTask != nil {
            stopMonitoring()
            runMacFocusShortcut(on: false)
            notifications.flushHeld(reason: "Focus session ended")
            Task { await deliverSessionSummary() }
            notifyStateChanged()
        }
    }

    // MARK: Session lifecycle

    func startSession() {
        guard isEnabled else { return }
        guard !isSessionActive else { return }
        try? stores.setValue("1", forKey: Self.sessionKey)
        try? stores.setValue(String(Date.now.timeIntervalSince1970), forKey: Self.sessionStartKey)
        sessionApps = [:]
        lastBreakNudge = .now
        lastDriftNudge = .distantPast
        driftingSince = nil
        runMacFocusShortcut(on: true)
        startMonitoring()
        try? stores.record(ActivityEvent(
            kind: .notificationSent, connectorID: "focus", summary: "Focus session started"))
        notifyStateChanged()
    }

    func endSession() {
        let wasActive = isSessionActive
        try? stores.setValue("0", forKey: Self.sessionKey)
        stopMonitoring()
        runMacFocusShortcut(on: false)
        notifications.flushHeld(reason: "Focus session ended")
        if wasActive {
            Task { await deliverSessionSummary() }
            try? stores.record(ActivityEvent(
                kind: .notificationSent, connectorID: "focus", summary: "Focus session ended"))
        }
        notifyStateChanged()
    }

    private func notifyStateChanged() {
        NotificationCenter.default.post(name: .aitvarasFocusChanged, object: nil)
        NotificationCenter.default.post(name: .aitvarasActivityChanged, object: nil)
    }

    // MARK: Monitoring

    private func startMonitoring() {
        guard samplerTask == nil else { return }
        continuousActiveSince = .now
        samplerTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.takeSample()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        driftTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.driftCheckInterval ?? 240))
                await self?.checkDrift()
            }
        }
    }

    private func stopMonitoring() {
        samplerTask?.cancel(); samplerTask = nil
        driftTask?.cancel(); driftTask = nil
        samples.removeAll()
        continuousActiveSince = nil
        driftingSince = nil
    }

    private func takeSample() {
        let idle = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: CGEventType(rawValue: ~0)!)

        if idle > 3 * 60 {
            // Stepped away — that's a break: deliver held updates now.
            if continuousActiveSince != nil {
                Task { await self.deliverBreakBriefing(trigger: "While you were away") }
            }
            continuousActiveSince = nil
            return
        }
        if continuousActiveSince == nil { continuousActiveSince = .now }

        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
        samples.append(Sample(at: .now, app: app))
        samples.removeAll { $0.at < Date.now.addingTimeInterval(-2 * 60 * 60) }
        sessionApps[app, default: 0] += 1

        checkBreakTime()
    }

    private func checkBreakTime() {
        let interval = TimeInterval(breakIntervalMinutes) * 60
        guard let since = continuousActiveSince,
              Date.now.timeIntervalSince(since) > interval,
              Date.now.timeIntervalSince(lastBreakNudge) > interval else { return }
        lastBreakNudge = .now
        Task { await deliverBreakBriefing(trigger: "Time for a short break") }
    }

    // MARK: Break + session briefings (model-composed)

    private func deliverBreakBriefing(trigger: String) async {
        let held = notifications.takeHeld()
        let breakLine = trigger.contains("away")
            ? "Welcome back."
            : "You've been focused for a while — time for a short break. Stretch, water, look away from the screen."

        if held.isEmpty {
            notifications.speakOrPost(title: trigger, body: breakLine.contains("Welcome") ? "" : "Stretch and rest your eyes.", urgent: true)
            try? stores.record(ActivityEvent(kind: .notificationSent, connectorID: "focus", summary: trigger))
            return
        }

        let composed = await composeBriefing(
            intro: breakLine,
            items: held.map { "\($0.title): \($0.body)" })
        notifications.speakOrPost(title: "Break", body: composed, urgent: true)
        try? stores.record(ActivityEvent(
            kind: .notificationSent, connectorID: "focus",
            summary: "Break briefing (\(held.count) held)"))
        notifyStateChanged()
    }

    private func deliverSessionSummary() async {
        guard let start = sessionStart else { return }
        let minutes = Int(Date.now.timeIntervalSince(start) / 60)
        guard minutes >= 5 else { return }
        let topApps = sessionApps.sorted { $0.value > $1.value }.prefix(3)
            .map { "\($0.key) (\($0.value / 2)min)" }.joined(separator: ", ")
        let goals = (try? stores.goals(day: Goal.today())) ?? []
        let done = goals.filter(\.done).count

        let summary = await composeBriefing(
            intro: "Focus session over.",
            items: [
                "Duration: about \(minutes) minutes",
                "Main apps: \(topApps.isEmpty ? "none tracked" : topApps)",
                goals.isEmpty ? "No goals set today" : "Goals completed: \(done) of \(goals.count)"
            ])
        notifications.speakOrPost(title: "Session summary", body: summary, urgent: false)
    }

    /// Turns raw items into a natural spoken paragraph via the background
    /// model. Falls back to a plain join if the model is unavailable.
    private func composeBriefing(intro: String, items: [String]) async -> String {
        guard let engine = await router.engine(for: .background) else {
            return intro + " " + items.joined(separator: ". ")
        }
        let messages = [
            ChatMessage(role: .system, content: """
                You compose a short spoken briefing for a voice assistant. \
                Turn the facts into 1-3 natural English sentences, warm and concise. \
                No lists, no markdown, no symbols — it will be read aloud. \
                Lead with: "\(intro)". Group related items, note what's important, \
                stay brief. /no_think
                """),
            ChatMessage(role: .user, content: items.joined(separator: "\n"))
        ]
        var out = ""
        do {
            for try await chunk in await engine.complete(messages: messages, tools: [], tier: .background) {
                if case .text(let t) = chunk { out += t }
            }
        } catch {
            return intro + " " + items.joined(separator: ". ")
        }
        let cleaned = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? (intro + " " + items.joined(separator: ". ")) : cleaned
    }

    // MARK: Drift detection (responsive, rate-limited)

    private func checkDrift() async {
        guard isSessionActive, continuousActiveSince != nil else { return }
        let goals = (try? stores.goals(day: Goal.today())) ?? []
        let openGoals = goals.filter { !$0.done }
        guard !openGoals.isEmpty else { return }

        let cutoff = Date.now.addingTimeInterval(-driftCheckInterval)
        var minutes: [String: Int] = [:]
        for sample in samples where sample.at > cutoff {
            minutes[sample.app, default: 0] += 1
        }
        let usage = minutes.sorted { $0.value > $1.value }.prefix(5)
            .map { "\($0.key): \($0.value / 2)min" }.joined(separator: ", ")
        guard !usage.isEmpty else { return }

        guard let engine = await router.engine(for: .background) else { return }
        let messages = [
            ChatMessage(role: .system, content: """
                You are a gentle focus coach. Given today's goals and the apps used \
                in the last few minutes, decide if the user is plausibly working \
                toward a goal. Coding, terminal, notes, docs, and research browsing \
                are legitimate work. Only judge drift for clearly off-task use \
                (games, social feeds, video entertainment). Reply ONLY with JSON: \
                {"drifting": bool, "nudge": "one short friendly sentence or empty"}. /no_think
                """),
            ChatMessage(role: .user, content: """
                Goals still open: \(openGoals.map(\.text).joined(separator: "; "))
                App usage last few minutes: \(usage)
                """)
        ]
        var raw = ""
        do {
            for try await chunk in await engine.complete(messages: messages, tools: [], tier: .background) {
                if case .text(let t) = chunk { raw += t }
            }
        } catch { return }

        let drifting = (try? JSONSerialization.jsonObject(with: Data(
            raw[(raw.firstIndex(of: "{") ?? raw.startIndex)...(raw.lastIndex(of: "}") ?? raw.index(before: raw.endIndex))].utf8)))
            .flatMap { $0 as? [String: Any] }

        if drifting?["drifting"] as? Bool == true {
            if driftingSince == nil { driftingSince = .now }
            // Only nudge once drift is SUSTAINED, and not too often.
            guard let since = driftingSince,
                  Date.now.timeIntervalSince(since) >= sustainedDriftBeforeNudge,
                  Date.now.timeIntervalSince(lastDriftNudge) >= minGapBetweenDriftNudges,
                  let nudge = drifting?["nudge"] as? String, !nudge.isEmpty else { return }
            lastDriftNudge = .now
            driftingSince = nil
            notifications.deliver(title: "Aitvaras", body: nudge, urgent: true)
            try? stores.record(ActivityEvent(
                kind: .notificationSent, connectorID: "focus",
                summary: "Focus nudge: \(nudge)", detailJSON: #"{"usage":"\#(usage)"}"#))
            notifyStateChanged()
        } else {
            driftingSince = nil   // back on task
        }
    }

    // MARK: Optional macOS Focus automation via Shortcuts

    private func runMacFocusShortcut(on: Bool) {
        guard let base = try? stores.value(forKey: Self.macFocusShortcutKey) ?? nil, !base.isEmpty else { return }
        let name = on ? base : "\(base) Off"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", name]
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}

extension Notification.Name {
    static let aitvarasFocusChanged = Notification.Name("aitvarasFocusChanged")
}
