import Foundation
import Synchronization
import Testing
import AitvarasCore

@Suite struct CaptureSleepProtectionTests {
    @Test func audioOnlyAllowsDisplaySleepAndReleasesExactlyOnce() throws {
        let driver = FakeSleepDriver()
        let lease = try CaptureSleepProtectionLease(policy: .audioOnly, driver: driver)
        #expect(driver.snapshot.requests == [false])
        #expect(driver.snapshot.live.count == 1)
        lease.release()
        lease.release()
        #expect(driver.snapshot.live.isEmpty)
        #expect(driver.snapshot.releases.count == 1)
    }

    @Test func visualEvidenceProtectsBothSystemAndDisplay() throws {
        let driver = FakeSleepDriver()
        let lease = try CaptureSleepProtectionLease(policy: .visualEvidence, driver: driver)
        #expect(driver.snapshot.requests == [false, true])
        #expect(driver.snapshot.live.count == 2)
        lease.release()
        #expect(driver.snapshot.releases == [2, 1])
    }

    @Test func firstAssertionFailureOwnsNothing() {
        let driver = FakeSleepDriver(failAt: 1)
        #expect(throws: FakeSleepDriver.Failure.self) {
            try CaptureSleepProtectionLease(policy: .audioOnly, driver: driver)
        }
        #expect(driver.snapshot.live.isEmpty)
        #expect(driver.snapshot.releases.isEmpty)
    }

    @Test func displayAssertionFailureRollsBackSystemProtection() {
        let driver = FakeSleepDriver(failAt: 2)
        #expect(throws: FakeSleepDriver.Failure.self) {
            try CaptureSleepProtectionLease(policy: .visualEvidence, driver: driver)
        }
        #expect(driver.snapshot.live.isEmpty)
        #expect(driver.snapshot.releases == [1])
    }

    @Test func ownerLifetimeReleasesBothAssertions() throws {
        let driver = FakeSleepDriver()
        var lease: CaptureSleepProtectionLease? = try CaptureSleepProtectionLease(policy: .visualEvidence, driver: driver)
        #expect(lease?.policy == .visualEvidence)
        lease = nil
        #expect(driver.snapshot.live.isEmpty)
        #expect(driver.snapshot.releases == [2, 1])
    }

    @Test func labelsDoNotPromiseForcedSleepContinuity() {
        #expect(CaptureSleepProtectionStatus.protected(.audioOnly).summary.contains("Display darf schlafen"))
        for policy in [CaptureSleepProtectionPolicy.audioOnly, .visualEvidence] {
            #expect(CaptureSleepProtectionStatus.protected(policy).summary.contains("erzwungener Ruhezustand"))
        }
        #expect(CaptureSleepProtectionStatus.unavailable.summary.contains("nicht gestartet"))
    }
}

private final class FakeSleepDriver: CaptureSleepAssertionDriving {
    struct State {
        var requests: [Bool] = []
        var releases: [UInt32] = []
        var live: Set<UInt32> = []
    }
    struct Failure: Error {}
    let failAt: Int?
    private let state = Mutex(State())
    init(failAt: Int? = nil) { self.failAt = failAt }
    var snapshot: State { state.withLock { $0 } }
    func acquire(preventDisplayIdleSleep: Bool) throws -> UInt32 {
        try state.withLock {
            $0.requests.append(preventDisplayIdleSleep)
            if $0.requests.count == failAt { throw Failure() }
            let id = UInt32($0.requests.count)
            $0.live.insert(id)
            return id
        }
    }
    func release(_ assertion: UInt32) {
        state.withLock {
            $0.live.remove(assertion)
            $0.releases.append(assertion)
        }
    }
}
