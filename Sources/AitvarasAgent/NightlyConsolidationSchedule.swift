import Foundation
import AitvarasCore

public enum NightlyScheduleMode: String, Sendable, CaseIterable {
    case automatic
    case fixedTime
    case off

    public var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .fixedTime: "Fixed time"
        case .off: "Off"
        }
    }
}

public enum NightlyPowerPolicy: String, Sendable, CaseIterable {
    case batteryAboveThreshold
    case pluggedInOnly
    case always

    public var displayName: String {
        switch self {
        case .batteryAboveThreshold: "Above battery threshold"
        case .pluggedInOnly: "Plugged in only"
        case .always: "Always"
        }
    }
}

/// Profile-scoped controls for the sleep-time memory pass.
///
/// The default treats 04:00 as a daily boundary, not an alarm. A sleeping Mac
/// does nothing then; Aitvaras catches up after the next launch or wake, once
/// the machine has had a short time to settle.
public struct NightlyScheduleSettings: Sendable, Equatable {
    public static let modeKey = "consolidator.schedule.mode"
    public static let earliestMinuteKey = "consolidator.schedule.earliestMinute"
    public static let fixedMinuteKey = "consolidator.schedule.fixedMinute"
    public static let wakeDelayKey = "consolidator.schedule.wakeDelayMinutes"
    public static let powerPolicyKey = "consolidator.schedule.powerPolicy"
    public static let batteryThresholdKey = "consolidator.schedule.batteryThreshold"

    public static let defaultEarliestMinute = 4 * 60
    public static let defaultWakeDelayMinutes = 10
    public static let defaultBatteryThreshold = 20

    public var mode: NightlyScheduleMode
    public var earliestMinute: Int
    public var fixedMinute: Int
    public var wakeDelayMinutes: Int
    public var powerPolicy: NightlyPowerPolicy
    public var batteryThreshold: Int

    public init(
        mode: NightlyScheduleMode = .automatic,
        earliestMinute: Int = Self.defaultEarliestMinute,
        fixedMinute: Int = Self.defaultEarliestMinute,
        wakeDelayMinutes: Int = Self.defaultWakeDelayMinutes,
        powerPolicy: NightlyPowerPolicy = .batteryAboveThreshold,
        batteryThreshold: Int = Self.defaultBatteryThreshold
    ) {
        self.mode = mode
        self.earliestMinute = Self.validMinute(earliestMinute)
        self.fixedMinute = Self.validMinute(fixedMinute)
        self.wakeDelayMinutes = min(max(wakeDelayMinutes, 0), 120)
        self.powerPolicy = powerPolicy
        self.batteryThreshold = min(max(batteryThreshold, 5), 100)
    }

    public static func load(
        from defaults: UserDefaults = AitvarasPreferences.current
    ) -> Self {
        let mode = defaults.string(forKey: modeKey)
            .flatMap(NightlyScheduleMode.init(rawValue:)) ?? .automatic
        let power = defaults.string(forKey: powerPolicyKey)
            .flatMap(NightlyPowerPolicy.init(rawValue:)) ?? .batteryAboveThreshold
        return Self(
            mode: mode,
            earliestMinute: defaults.object(forKey: earliestMinuteKey) == nil
                ? defaultEarliestMinute : defaults.integer(forKey: earliestMinuteKey),
            fixedMinute: defaults.object(forKey: fixedMinuteKey) == nil
                ? defaultEarliestMinute : defaults.integer(forKey: fixedMinuteKey),
            wakeDelayMinutes: defaults.object(forKey: wakeDelayKey) == nil
                ? defaultWakeDelayMinutes : defaults.integer(forKey: wakeDelayKey),
            powerPolicy: power,
            batteryThreshold: defaults.object(forKey: batteryThresholdKey) == nil
                ? defaultBatteryThreshold : defaults.integer(forKey: batteryThresholdKey))
    }

    public func save(
        to defaults: UserDefaults = AitvarasPreferences.current
    ) {
        defaults.set(mode.rawValue, forKey: Self.modeKey)
        defaults.set(Self.validMinute(earliestMinute), forKey: Self.earliestMinuteKey)
        defaults.set(Self.validMinute(fixedMinute), forKey: Self.fixedMinuteKey)
        defaults.set(min(max(wakeDelayMinutes, 0), 120), forKey: Self.wakeDelayKey)
        defaults.set(powerPolicy.rawValue, forKey: Self.powerPolicyKey)
        defaults.set(min(max(batteryThreshold, 5), 100),
                     forKey: Self.batteryThresholdKey)
    }

    public var scheduledMinute: Int {
        mode == .fixedTime ? fixedMinute : earliestMinute
    }

    private static func validMinute(_ value: Int) -> Int {
        min(max(value, 0), 24 * 60 - 1)
    }
}

public struct NightlyPowerSnapshot: Sendable, Equatable {
    public var hasBattery: Bool
    public var isConnectedToPower: Bool
    public var batteryPercent: Int?

    public init(
        hasBattery: Bool,
        isConnectedToPower: Bool,
        batteryPercent: Int?
    ) {
        self.hasBattery = hasBattery
        self.isConnectedToPower = isConnectedToPower
        self.batteryPercent = batteryPercent.map { min(max($0, 0), 100) }
    }

    /// Conservative fallback for a desktop Mac or an unreadable power source.
    public static let externallyPowered = Self(
        hasBattery: false, isConnectedToPower: true, batteryPercent: nil)
}

public struct NightlyScheduleDecision: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case disabled
        case waiting
        case ready
        case completed
    }

    public var state: State
    public var reason: String
    public var nextEligibleAt: Date?
    public var dailyBoundary: Date?

    public init(
        state: State,
        reason: String,
        nextEligibleAt: Date? = nil,
        dailyBoundary: Date? = nil
    ) {
        self.state = state
        self.reason = reason
        self.nextEligibleAt = nextEligibleAt
        self.dailyBoundary = dailyBoundary
    }
}

public enum NightlyConsolidationSchedule {
    /// Pure scheduling policy used by both the app coordinator and tests.
    public static func decision(
        settings: NightlyScheduleSettings,
        lastSuccessfulRun: Date?,
        opportunityAt: Date,
        power: NightlyPowerSnapshot,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> NightlyScheduleDecision {
        guard settings.mode != .off else {
            return NightlyScheduleDecision(
                state: .disabled,
                reason: "Automatic nightly memory is turned off.")
        }
        guard let boundary = boundary(
            minuteOfDay: settings.scheduledMinute, containing: now, calendar: calendar)
        else {
            return NightlyScheduleDecision(
                state: .waiting,
                reason: "The next eligible time could not be calculated.")
        }

        if let lastSuccessfulRun, lastSuccessfulRun >= boundary {
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: boundary)
            return NightlyScheduleDecision(
                state: .completed,
                reason: "Today’s nightly memory update is complete.",
                nextEligibleAt: tomorrow,
                dailyBoundary: boundary)
        }

        let graceEnd = opportunityAt.addingTimeInterval(
            TimeInterval(settings.wakeDelayMinutes * 60))
        let timeEligibleAt = max(boundary, graceEnd)
        guard now >= timeEligibleAt else {
            let waitingForBoundary = boundary >= graceEnd
            return NightlyScheduleDecision(
                state: .waiting,
                reason: waitingForBoundary
                    ? "Waiting for today’s configured memory-update time."
                    : "Waiting \(settings.wakeDelayMinutes) minutes after launch or wake so the Mac can settle.",
                nextEligibleAt: timeEligibleAt,
                dailyBoundary: boundary)
        }

        if let powerReason = unsuitablePowerReason(settings: settings, power: power) {
            return NightlyScheduleDecision(
                state: .waiting,
                reason: powerReason,
                nextEligibleAt: nil,
                dailyBoundary: boundary)
        }

        return NightlyScheduleDecision(
            state: .ready,
            reason: "Ready to update memory.",
            nextEligibleAt: now,
            dailyBoundary: boundary)
    }

    private static func boundary(
        minuteOfDay: Int,
        containing now: Date,
        calendar: Calendar
    ) -> Date? {
        let start = calendar.startOfDay(for: now)
        return calendar.date(
            byAdding: .minute,
            value: min(max(minuteOfDay, 0), 24 * 60 - 1),
            to: start)
    }

    private static func unsuitablePowerReason(
        settings: NightlyScheduleSettings,
        power: NightlyPowerSnapshot
    ) -> String? {
        switch settings.powerPolicy {
        case .always:
            return nil
        case .pluggedInOnly:
            return power.isConnectedToPower
                ? nil : "Waiting until the Mac is connected to power."
        case .batteryAboveThreshold:
            guard power.hasBattery, !power.isConnectedToPower else { return nil }
            guard let percent = power.batteryPercent else {
                return "Waiting until battery state is available or the Mac is connected to power."
            }
            return percent >= settings.batteryThreshold
                ? nil
                : "Waiting for at least \(settings.batteryThreshold)% battery or external power."
        }
    }
}
