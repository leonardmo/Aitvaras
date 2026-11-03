import Foundation
import Testing
@testable import AitvarasAgent

@Suite struct NightlyConsolidationScheduleTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(
        _ day: Int = 24,
        hour: Int,
        minute: Int = 0
    ) -> Date {
        calendar.date(from: DateComponents(
            year: 2026, month: 7, day: day, hour: hour, minute: minute))!
    }

    @Test func defaultsUseReliableCatchUpRatherThanExactAlarm() {
        let settings = NightlyScheduleSettings()

        #expect(settings.mode == .automatic)
        #expect(settings.earliestMinute == 4 * 60)
        #expect(settings.wakeDelayMinutes == 10)
        #expect(settings.powerPolicy == .batteryAboveThreshold)
        #expect(settings.batteryThreshold == 20)
    }

    @Test func automaticLaunchAfterBoundaryWaitsForSettlingDelay() {
        let launch = date(hour: 8)
        let beforeGrace = NightlyConsolidationSchedule.decision(
            settings: .init(),
            lastSuccessfulRun: nil,
            opportunityAt: launch,
            power: .externallyPowered,
            now: date(hour: 8, minute: 9),
            calendar: calendar)
        #expect(beforeGrace.state == .waiting)
        #expect(beforeGrace.nextEligibleAt == date(hour: 8, minute: 10))

        let afterGrace = NightlyConsolidationSchedule.decision(
            settings: .init(),
            lastSuccessfulRun: nil,
            opportunityAt: launch,
            power: .externallyPowered,
            now: date(hour: 8, minute: 10),
            calendar: calendar)
        #expect(afterGrace.state == .ready)
    }

    @Test func appAlreadyAwakeWaitsOnlyForDailyBoundary() {
        let decision = NightlyConsolidationSchedule.decision(
            settings: .init(),
            lastSuccessfulRun: nil,
            opportunityAt: date(hour: 2),
            power: .externallyPowered,
            now: date(hour: 3),
            calendar: calendar)

        #expect(decision.state == .waiting)
        #expect(decision.nextEligibleAt == date(hour: 4))
    }

    @Test func completedDayRunsOnlyOnceAndReportsTomorrow() {
        let decision = NightlyConsolidationSchedule.decision(
            settings: .init(),
            lastSuccessfulRun: date(hour: 8),
            opportunityAt: date(hour: 7),
            power: .externallyPowered,
            now: date(hour: 12),
            calendar: calendar)

        #expect(decision.state == .completed)
        #expect(decision.nextEligibleAt == date(25, hour: 4))
    }

    @Test func fixedTimeAlsoCatchesUpAfterMissedSleepingTime() {
        let settings = NightlyScheduleSettings(
            mode: .fixedTime,
            fixedMinute: 22 * 60,
            wakeDelayMinutes: 10,
            powerPolicy: .always)
        let decision = NightlyConsolidationSchedule.decision(
            settings: settings,
            lastSuccessfulRun: nil,
            opportunityAt: date(hour: 23),
            power: .externallyPowered,
            now: date(hour: 23, minute: 10),
            calendar: calendar)

        #expect(decision.state == .ready)
        #expect(decision.dailyBoundary == date(hour: 22))
    }

    @Test func batteryPolicyDefersWithoutBlockingPoweredDesktops() {
        let settings = NightlyScheduleSettings(
            wakeDelayMinutes: 0,
            powerPolicy: .batteryAboveThreshold,
            batteryThreshold: 30)
        let lowBattery = NightlyConsolidationSchedule.decision(
            settings: settings,
            lastSuccessfulRun: nil,
            opportunityAt: date(hour: 5),
            power: NightlyPowerSnapshot(
                hasBattery: true,
                isConnectedToPower: false,
                batteryPercent: 15),
            now: date(hour: 5),
            calendar: calendar)
        #expect(lowBattery.state == .waiting)
        #expect(lowBattery.reason.contains("30%"))

        let desktop = NightlyConsolidationSchedule.decision(
            settings: settings,
            lastSuccessfulRun: nil,
            opportunityAt: date(hour: 5),
            power: .externallyPowered,
            now: date(hour: 5),
            calendar: calendar)
        #expect(desktop.state == .ready)
    }

    @Test func pluggedInOnlyAndOffModesAreExplicit() {
        let battery = NightlyPowerSnapshot(
            hasBattery: true, isConnectedToPower: false, batteryPercent: 90)
        let pluggedOnly = NightlyConsolidationSchedule.decision(
            settings: .init(
                wakeDelayMinutes: 0, powerPolicy: .pluggedInOnly),
            lastSuccessfulRun: nil,
            opportunityAt: date(hour: 5),
            power: battery,
            now: date(hour: 5),
            calendar: calendar)
        #expect(pluggedOnly.state == .waiting)
        #expect(pluggedOnly.reason.contains("connected to power"))

        let off = NightlyConsolidationSchedule.decision(
            settings: .init(mode: .off),
            lastSuccessfulRun: nil,
            opportunityAt: date(hour: 5),
            power: battery,
            now: date(hour: 5),
            calendar: calendar)
        #expect(off.state == .disabled)
        #expect(off.nextEligibleAt == nil)
    }

    @Test func profileSettingsRoundTripAndClampUnsafeValues() throws {
        let suiteName = "app.aitvaras.tests.nightly.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = NightlyScheduleSettings(
            mode: .fixedTime,
            earliestMinute: -20,
            fixedMinute: 30 * 60,
            wakeDelayMinutes: 500,
            powerPolicy: .pluggedInOnly,
            batteryThreshold: 2)

        settings.save(to: defaults)
        let loaded = NightlyScheduleSettings.load(from: defaults)

        #expect(loaded.mode == .fixedTime)
        #expect(loaded.earliestMinute == 0)
        #expect(loaded.fixedMinute == 23 * 60 + 59)
        #expect(loaded.wakeDelayMinutes == 120)
        #expect(loaded.powerPolicy == .pluggedInOnly)
        #expect(loaded.batteryThreshold == 5)
    }
}
