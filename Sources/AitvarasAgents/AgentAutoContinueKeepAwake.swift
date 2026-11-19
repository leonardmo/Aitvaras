import Foundation
import IOKit.pwr_mgt
import IOKit.ps
import AitvarasCore

public enum AgentAutoContinuePower: Sendable { case ac, battery, unknown }
public enum AgentAutoContinuePowerError: Error, Sendable, Equatable { case createFailed, releaseFailed }

public struct AgentAutoContinueAssertionDriver: Sendable {
    public let create: @Sendable () throws -> UInt32
    public let release: @Sendable (UInt32) throws -> Void
    /// The system driver rechecks power even when queued notifications are stale.
    public let currentPower: @Sendable () -> AgentAutoContinuePower?
    public init(create: @escaping @Sendable () throws -> UInt32, release: @escaping @Sendable (UInt32) throws -> Void,
                currentPower: @escaping @Sendable () -> AgentAutoContinuePower? = { nil }) {
        self.create = create; self.release = release; self.currentPower = currentPower
    }
    public static let system = Self(create: {
        guard AgentAutoContinuePowerSource.current() == .ac else { throw AgentAutoContinuePowerError.createFailed }
        var id: IOPMAssertionID = 0
        guard IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), "Aitvaras usage-reset continuation" as CFString, &id) == kIOReturnSuccess else {
            throw AgentAutoContinuePowerError.createFailed
        }
        return id
    }, release: { id in
        guard IOPMAssertionRelease(id) == kIOReturnSuccess else { throw AgentAutoContinuePowerError.releaseFailed }
    }, currentPower: { AgentAutoContinuePowerSource.current() })
}

public enum AgentAutoContinuePowerSource {
    /// Unlike nightly scheduling, missing power information never means AC.
    public static func current() -> AgentAutoContinuePower {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return .unknown }
        switch source as String {
        case kIOPSACPowerValue: return .ac
        case kIOPSBatteryPowerValue: return .battery
        default: return .unknown
        }
    }
}

/// One idle-sleep assertion shared by all eligible intents; never schedules a wake.
public actor AgentAutoContinueKeepAwake {
    private let persistence: any AgentAutoContinuePersistence
    private let driver: AgentAutoContinueAssertionDriver
    private let audit: AgentActionCoordinator.Audit
    private let clock: AgentAutoContinueClock
    private let policy: AutonomyPolicy
    private var active: Bool
    private var power = AgentAutoContinuePower.unknown
    private var powerVersion = 0
    private var assertion: UInt32?
    private var owner: AgentAutoContinue?
    private var reconciling = false
    private var dirty = false

    public init(persistence: any AgentAutoContinuePersistence, driver: AgentAutoContinueAssertionDriver = .system,
                audit: @escaping AgentActionCoordinator.Audit, clock: AgentAutoContinueClock = .live,
                policy: AutonomyPolicy = .init(), enabled: Bool = false) {
        self.persistence = persistence; self.driver = driver; self.audit = audit; self.clock = clock
        self.policy = policy; active = enabled
    }
    deinit { if let assertion { try? driver.release(assertion) } }
    public var isHolding: Bool { assertion != nil }

    public func setActive(_ enabled: Bool) async throws {
        active = enabled; powerVersion += 1
        try await refresh()
    }
    public func updatePower(_ value: AgentAutoContinuePower) async throws {
        power = value; powerVersion += 1
        try await refresh()
    }
    public func shutdown() async throws { try await setActive(false) }

    private func eligible() throws -> AgentAutoContinue? {
        guard active, power == .ac else { return nil }
        if let actual = driver.currentPower(), actual != .ac { return nil }
        return try persistence.pending().first { value in
            guard value.enabled, value.keepAwake, value.scope.hasKnownAccount,
                  value.state != .claimed || value.delivery == .prepared else { return false }
            var pending = value; pending.state = .pending
            let plan = AgentAutoContinueSchedule(clock: clock).plan(pending)
            guard plan.state == .waiting || plan.state == .ready else { return false }
            return try persistence.hasValidSession(value)
        }
    }
    public func refresh() async throws {
        // Release immediately, even if an earlier audit is suspended or storage fails.
        let desired: AgentAutoContinue?
        do { desired = try eligible() }
        catch { try await release(); throw error }
        if desired == nil { try await release() }
        if reconciling { dirty = true; return }
        reconciling = true
        defer { reconciling = false }
        repeat {
            dirty = false
            guard let desired = try eligible() else { try await release(); continue }
            if assertion != nil {
                if owner?.id != desired.id {
                    let id = assertion
                    try await record("transferred", for: desired)
                    guard assertion == id, try eligible()?.id == desired.id else { dirty = true; continue }
                    owner = desired
                }
                continue
            }
            let tool = ToolDefinition(name: "keepAwake", description: "Prevent idle sleep while waiting", parametersJSON: "{}", risk: .reversibleWrite)
            guard policy.verdict(for: tool, connectorID: "agent.autoContinue") == .allow else { throw AgentFailure.invalidTransition }
            let version = powerVersion
            try await record("requested", for: desired)
            guard version == powerVersion, let current = try eligible(), current == desired else { dirty = true; continue }
            do { assertion = try driver.create(); owner = current }
            catch { try? await record("createFailed", for: current); throw error }
        } while dirty
    }
    private func release() async throws {
        guard let assertion else { return }
        try driver.release(assertion)
        self.assertion = nil
        let previous = owner; owner = nil
        // Audit failure must never leave an assertion held on battery or shutdown.
        if let previous { try await record("released", for: previous) }
    }
    private func record(_ status: String, for value: AgentAutoContinue) async throws {
        try await audit(ActivityEvent(kind: .automationRun, timestamp: clock.now(), connectorID: "agent.autoContinue",
            summary: "Usage-reset keep-awake: " + status,
            detailJSON: JSONValue.object(["operation": .string("keepAwake"), "status": .string(status),
                "intentID": .string(value.id.uuidString), "inputID": .string(value.failedInputID.uuidString),
                "risk": .string("reversibleWrite")]).jsonString,
            causedBy: value.lastActivityID, sourceID: value.failedInputID.uuidString, runID: value.failedInputID))
    }
}
