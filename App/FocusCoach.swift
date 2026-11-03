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
    private let reporter: ActivityReporter?
    private var activityID: UUID?

    private var samplerTask: Task<Void, Never>?
    private var driftTask: Task<Void, Never>?
    private var shortcutTask: Task<Void, Never>?

    private struct Sample { let at: Date; let app: String }
    private var samples: [Sample] = []
    private var continuousActiveSince: Date?
    private var driftingSince: Date?
    private var lastBreakNudge: Date = .distantPast
    private var lastDriftNudge: Date = .distantPast
    private var sessionApps: [String: Int] = [:]     // whole-session app tally
    /// UI and routing read the last complete durable snapshot. A temporary
    /// database failure must not turn a known running session into "off".
    private var cachedEnabled = false
    private var cachedSessionActive = false
    private var cachedSessionStart: Date?
    private var cachedBreakIntervalMinutes = 50

    /// How responsive drift detection is, and how it's rate-limited.
    private let driftCheckInterval: TimeInterval = 4 * 60
    private let sustainedDriftBeforeNudge: TimeInterval = 5 * 60
    private let minGapBetweenDriftNudges: TimeInterval = 15 * 60

    init(stores: Stores, router: EngineRouter, notifications: NotificationRouter, reporter: ActivityReporter? = nil) {
        self.stores = stores
        self.router = router
        self.notifications = notifications
        self.reporter = reporter
    }

    deinit {
        samplerTask?.cancel()
        driftTask?.cancel()
        shortcutTask?.cancel()
    }

    // MARK: Capability + session state

    var isEnabled: Bool {
        cachedEnabled
    }

    var isSessionActive: Bool {
        cachedSessionActive
    }

    var sessionStart: Date? {
        cachedSessionStart
    }

    var breakIntervalMinutes: Int {
        cachedBreakIntervalMinutes
    }

    func setBreakInterval(minutes: Int) throws {
        let bounded = max(10, min(180, minutes))
        try stores.setValue(String(bounded), forKey: Self.breakIntervalKey)
        cachedBreakIntervalMinutes = bounded
    }

    func setEnabled(_ enabled: Bool) throws {
        let wasActive = try storedSessionActive()
        if enabled {
            try stores.setValue("1", forKey: Self.enabledKey)
        } else {
            try stores.setValues([
                Self.enabledKey: "0",
                Self.sessionKey: "0"
            ])
        }
        cachedEnabled = enabled
        if !enabled { cachedSessionActive = false }
        if enabled {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        } else {
            finishSession(wasActive: wasActive)
        }
    }

    /// Resume a session that was active when the app last quit.
    func startIfSessionActive() {
        do {
            let state = try readStoredState()
            apply(state)
            if state.enabled, state.active {
                runMacFocusShortcut(on: true)
                startMonitoring()
            }
        } catch {
            notifications.reportError?("Focus session state could not be restored", error)
        }
    }

    /// A previous process's observation session never silently resumes.
    func suspendRestoredSession() {
        do {
            let state = try readStoredState()
            apply(state)
            if state.active { try stores.setValue("0", forKey: Self.sessionKey) }
            cachedSessionActive = false
            stopMonitoring()
        } catch { notifications.reportError?("Focus state needs attention", error) }
    }

    func suspendMonitoring() {
        if let activityID { reporter?.finish(id: activityID, state: .interrupted, outcome: "Observation paused; start a new focus session explicitly") }
        activityID = nil
        stopMonitoring()
        shortcutTask?.cancel()
        if cachedSessionActive {
            try? stores.setValue("0", forKey: Self.sessionKey)
            cachedSessionActive = false
            notifyStateChanged()
        }
    }

    /// Bring monitoring in line with the stored session flag — the flag
    /// can be flipped from voice/chat tools (which only write the store),
    /// so the app calls this after turns to start/stop the coach tasks.
    func reconcile() {
        do {
            let state = try readStoredState()
            apply(state)
            guard state.enabled else { stopMonitoring(); return }
            if state.active, samplerTask == nil {
                sessionApps = [:]; lastBreakNudge = .now; lastDriftNudge = .distantPast; driftingSince = nil
                runMacFocusShortcut(on: true)
                startMonitoring()
                notifyStateChanged()
            } else if !state.active, samplerTask != nil {
                stopMonitoring()
                runMacFocusShortcut(on: false)
                notifications.flushHeld(reason: "Focus session ended")
                Task { await deliverSessionSummary() }
                notifyStateChanged()
            }
        } catch {
            // A failed durable read is not the same as a disabled or ended
            // session. Preserve the last monitoring state and surface it.
            notifications.reportError?("Focus session state could not be refreshed", error)
        }
    }

    // MARK: Session lifecycle

    func startSession() throws {
        guard try storedEnabled() else {
            throw FocusSessionError("Enable Focus Coach in Connections before starting a session.")
        }
        guard try !storedSessionActive() else { return }
        let startedAt = Date.now
        try stores.setValues([
            Self.sessionKey: "1",
            Self.sessionStartKey: String(startedAt.timeIntervalSince1970)
        ])
        cachedEnabled = true
        cachedSessionActive = true
        cachedSessionStart = startedAt
        sessionApps = [:]
        lastBreakNudge = .now
        lastDriftNudge = .distantPast
        driftingSince = nil
        runMacFocusShortcut(on: true)
        startMonitoring()
        recordActivity(ActivityEvent(
            kind: .notificationSent, connectorID: "focus", summary: "Focus session started"))
        notifyStateChanged()
    }

    func endSession() throws {
        let wasActive = try storedSessionActive()
        try stores.setValue("0", forKey: Self.sessionKey)
        cachedSessionActive = false
        finishSession(wasActive: wasActive)
    }

    private func storedEnabled() throws -> Bool {
        try stores.value(forKey: Self.enabledKey) == "1"
    }

    private func storedSessionActive() throws -> Bool {
        try stores.value(forKey: Self.sessionKey) == "1"
    }

    private struct StoredState {
        var enabled: Bool
        var active: Bool
        var start: Date?
        var breakIntervalMinutes: Int
    }

    /// Read every field before replacing the cache, so a partial database
    /// failure cannot produce a half-new state in the UI.
    private func readStoredState() throws -> StoredState {
        let enabled = try storedEnabled()
        var active = try storedSessionActive()
        // This combination can only be left by an interrupted/older build.
        // Repair it before notification routing sees a focus hold that no
        // coach task will ever drain.
        if active, !enabled {
            try stores.setValue("0", forKey: Self.sessionKey)
            active = false
        }
        let startRaw = try stores.value(forKey: Self.sessionStartKey)
        let start = startRaw.flatMap(Double.init)
            .map(Date.init(timeIntervalSince1970:))
        let intervalRaw = try stores.value(forKey: Self.breakIntervalKey)
        let interval = intervalRaw.flatMap(Int.init).map { max(10, min(180, $0)) } ?? 50
        return StoredState(
            enabled: enabled, active: active, start: start,
            breakIntervalMinutes: interval)
    }

    private func apply(_ state: StoredState) {
        cachedEnabled = state.enabled
        cachedSessionActive = state.active
        cachedSessionStart = state.start
        cachedBreakIntervalMinutes = state.breakIntervalMinutes
    }

    private func finishSession(wasActive: Bool) {
        stopMonitoring()
        runMacFocusShortcut(on: false)
        notifications.flushHeld(reason: "Focus session ended")
        if wasActive {
            Task { await deliverSessionSummary() }
            recordActivity(ActivityEvent(
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
        activityID = reporter?.begin(ActivityRun(category: .automation, title: "Focus session",
            stage: "Observing app activity locally", executionLocation: "This Mac",
            dataAccess: "Active app and idle-time metadata", dataDestination: "Local processing only"))
        continuousActiveSince = .now
        samplerTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.takeSample()
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
        driftTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(self?.driftCheckInterval ?? 240)) } catch { return }
                guard !Task.isCancelled, self?.cachedSessionActive == true else { return }
                await self?.checkDrift()
            }
        }
    }

    private func stopMonitoring() {
        if let activityID { reporter?.finish(id: activityID, state: .succeeded, outcome: "Focus observation ended") }
        activityID = nil
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
        let held = notifications.heldItems()
        let breakLine = trigger.contains("away")
            ? "Welcome back."
            : "You've been focused for a while — time for a short break. Stretch, water, look away from the screen."

        if held.isEmpty {
            notifications.speakOrPost(title: trigger, body: breakLine.contains("Welcome") ? "" : "Stretch and rest your eyes.", urgent: true)
            recordActivity(ActivityEvent(
                kind: .notificationSent, connectorID: "focus", summary: trigger))
            return
        }

        let composed = await composeBriefing(
            intro: breakLine,
            items: held.map { "\($0.title): \($0.body)" })
        notifications.speakOrPost(title: "Break", body: composed, urgent: true)
        notifications.markDelivered(held)
        recordActivity(ActivityEvent(
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
        let goalLine: String
        do {
            let goals = try stores.goals(day: Goal.today())
            let done = goals.filter(\.done).count
            goalLine = goals.isEmpty
                ? "No goals set today"
                : "Goals completed: \(done) of \(goals.count)"
        } catch {
            notifications.reportError?("Goals could not be loaded for the focus summary", error)
            goalLine = "Goal status unavailable"
        }

        let summary = await composeBriefing(
            intro: "Focus session over.",
            items: [
                "Duration: about \(minutes) minutes",
                "Main apps: \(topApps.isEmpty ? "none tracked" : topApps)",
                goalLine
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
            for try await chunk in await engine.completeWithInactivityTimeout(
                messages: messages, tools: [], tier: .background) {
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
        let goals: [Goal]
        do {
            goals = try stores.goals(day: Goal.today())
        } catch {
            notifications.reportError?("Goals could not be loaded for focus coaching", error)
            return
        }
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
            for try await chunk in await engine.completeWithInactivityTimeout(
                messages: messages, tools: [], tier: .background) {
                if case .text(let t) = chunk { raw += t }
            }
        } catch { return }

        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"), start <= end,
              let drifting = (try? JSONSerialization.jsonObject(
                with: Data(raw[start...end].utf8))) as? [String: Any] else {
            return
        }

        if drifting["drifting"] as? Bool == true {
            if driftingSince == nil { driftingSince = .now }
            // Only nudge once drift is SUSTAINED, and not too often.
            guard let since = driftingSince,
                  Date.now.timeIntervalSince(since) >= sustainedDriftBeforeNudge,
                  Date.now.timeIntervalSince(lastDriftNudge) >= minGapBetweenDriftNudges,
                  let nudge = drifting["nudge"] as? String, !nudge.isEmpty else { return }
            lastDriftNudge = .now
            driftingSince = nil
            notifications.deliver(title: "Aitvaras", body: nudge, urgent: true)
            // App usage is deliberately memory-only. Do not attach `usage`
            // to this durable event even though it helped the local model.
            recordActivity(ActivityEvent(
                kind: .notificationSent, connectorID: "focus",
                summary: "Focus nudge: \(nudge)"))
            notifyStateChanged()
        } else {
            driftingSince = nil   // back on task
        }
    }

    // MARK: Optional macOS Focus automation via Shortcuts

    private func runMacFocusShortcut(on: Bool) {
        let base: String
        do {
            guard let saved = try stores.value(forKey: Self.macFocusShortcutKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !saved.isEmpty else { return }
            base = saved
        } catch {
            notifications.reportError?("Focus shortcut could not be loaded", error)
            return
        }

        let name = on ? base : "\(base) Off"
        shortcutTask?.cancel()
        shortcutTask = Task { [weak self] in
            do {
                let output = try await DisclaimedProcess.run(
                    executable: "/usr/bin/shortcuts",
                    arguments: ["run", name],
                    timeout: 30)
                guard output.exitCode == 0 else {
                    throw FocusSessionError(
                        "The macOS Shortcut exited with code \(output.exitCode).")
                }
            } catch is CancellationError {
                return
            } catch {
                self?.notifications.reportError?("Focus shortcut could not run", error)
            }
        }
    }

    private func recordActivity(_ event: ActivityEvent) {
        do {
            _ = try stores.record(event)
        } catch {
            notifications.reportError?("Focus activity could not be saved", error)
        }
    }
}

extension Notification.Name {
    static let aitvarasFocusChanged = Notification.Name("aitvarasFocusChanged")
}

private struct FocusSessionError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
