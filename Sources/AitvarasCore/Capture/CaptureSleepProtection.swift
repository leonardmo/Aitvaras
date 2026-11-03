import Foundation
import IOKit.pwr_mgt
import Synchronization

/// Only idle sleep is inhibited. Lid closure, explicit sleep, low battery and
/// other system sleep reasons can still interrupt capture; this is not a wake lock.
public enum CaptureSleepProtectionPolicy: Equatable, Sendable {
    case audioOnly
    case visualEvidence

    public var preventsDisplayIdleSleep: Bool { self == .visualEvidence }
}

public enum CaptureSleepProtectionStatus: Equatable, Sendable {
    case inactive
    case protected(CaptureSleepProtectionPolicy)
    case unavailable

    public var summary: String {
        switch self {
        case .inactive:
            "Kein Aufnahme-Ruhezustandsschutz aktiv."
        case .protected(.audioOnly):
            "Aufnahme: automatischer Systemruhezustand verhindert; Display darf schlafen. Zuklappen oder erzwungener Ruhezustand unterbricht die Aufnahme."
        case .protected(.visualEvidence):
            "Aufnahme: automatischer System- und Displayruhezustand verhindert. Zuklappen oder erzwungener Ruhezustand unterbricht die Aufnahme."
        case .unavailable:
            "Ruhezustandsschutz nicht verfügbar — Aufnahme wurde nicht gestartet."
        }
    }
}

public protocol CaptureSleepAssertionDriving: Sendable {
    func acquire(preventDisplayIdleSleep: Bool) throws -> UInt32
    func release(_ assertion: UInt32)
}

/// One lease per explicit capture, never owned by saving or analysis tasks.
/// Partial acquisition rolls back; explicit cleanup and deinit are idempotent.
public final class CaptureSleepProtectionLease: Sendable {
    public let policy: CaptureSleepProtectionPolicy
    private let driver: any CaptureSleepAssertionDriving
    private let assertions: Mutex<[UInt32]>

    public init(policy: CaptureSleepProtectionPolicy,
                driver: any CaptureSleepAssertionDriving) throws {
        self.policy = policy
        self.driver = driver
        var acquired: [UInt32] = []
        do {
            acquired.append(try driver.acquire(preventDisplayIdleSleep: false))
            if policy.preventsDisplayIdleSleep {
                acquired.append(try driver.acquire(preventDisplayIdleSleep: true))
            }
        } catch {
            for assertion in acquired.reversed() { driver.release(assertion) }
            throw error
        }
        assertions = Mutex(acquired)
    }

    public func release() {
        let owned = assertions.withLock { value in
            let owned = value
            value.removeAll()
            return owned
        }
        for assertion in owned.reversed() { driver.release(assertion) }
    }

    deinit { release() }
}

public struct NativeCaptureSleepAssertionDriver: CaptureSleepAssertionDriving {
    public init() {}

    public func acquire(preventDisplayIdleSleep: Bool) throws -> UInt32 {
        let type = preventDisplayIdleSleep
            ? kIOPMAssertionTypePreventUserIdleDisplaySleep
            : kIOPMAssertionTypePreventUserIdleSystemSleep
        var identifier = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Aitvaras explicit recording" as CFString, &identifier)
        guard result == kIOReturnSuccess else { throw AssertionError(code: result) }
        return identifier
    }

    public func release(_ assertion: UInt32) { _ = IOPMAssertionRelease(assertion) }

    private struct AssertionError: LocalizedError {
        let code: IOReturn
        var errorDescription: String? {
            "Ruhezustandsschutz konnte nicht aktiviert werden (macOS \(code)). Es wurden keine Aufnahmeeingänge gestartet."
        }
    }
}
