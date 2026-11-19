import Foundation

public enum AgentAutoContinueLifecycleFailure: Sendable, Equatable { case power, scheduling }

/// Lifecycle orchestration only. Native notifications and power observation stay thin.
public actor AgentAutoContinueLifecycle {
    private let manager: AgentSessionManager
    private let scheduler: AgentAutoContinueScheduler
    private let keepAwake: AgentAutoContinueKeepAwake
    private var running = false
    private var generation = UUID()
    private var listener: Task<Void, Never>?
    public private(set) var lastFailure: AgentAutoContinueLifecycleFailure?

    public init(manager: AgentSessionManager, scheduler: AgentAutoContinueScheduler, keepAwake: AgentAutoContinueKeepAwake) {
        self.manager = manager; self.scheduler = scheduler; self.keepAwake = keepAwake
    }
    deinit { listener?.cancel() }
    public func launch(power: AgentAutoContinuePower) async throws {
        if running { try await didWake(power: power); return }
        generation = UUID(); running = true
        let generation = generation
        // Refresh the power snapshot before activating; never reuse pre-quit AC.
        var failure: (any Error)?
        do { try await keepAwake.updatePower(power) }
        catch { lastFailure = .power; failure = error }
        guard current(generation) else { return }
        let updates = await scheduler.updates()
        guard current(generation) else { return }
        listener = Task { [weak self] in
            for await _ in updates {
                guard !Task.isCancelled else { break }
                await self?.schedulingChanged(generation)
            }
        }
        do { try await keepAwake.setActive(true) }
        catch { lastFailure = .power; failure = error }
        guard current(generation) else { return }
        // Assertion failure must not prevent the continuation itself.
        do { try await scheduler.start() }
        catch { lastFailure = .scheduling; failure = failure ?? error }
        guard current(generation) else { return }
        do { try await keepAwake.refresh() }
        catch { lastFailure = .power; failure = failure ?? error }
        if let failure { throw failure }
    }
    public func didWake(power: AgentAutoContinuePower) async throws {
        guard running else { return }
        let generation = generation
        var failure: (any Error)?
        do { try await keepAwake.updatePower(power) }
        catch { lastFailure = .power; failure = error }
        guard current(generation) else { return }
        do { try await scheduler.wake() }
        catch { lastFailure = .scheduling; failure = failure ?? error }
        guard current(generation) else { return }
        do { try await keepAwake.refresh() }
        catch { lastFailure = .power; failure = failure ?? error }
        if let failure { throw failure }
    }
    public func powerChanged(_ power: AgentAutoContinuePower) async throws {
        guard running else { return }
        do { try await keepAwake.updatePower(power) }
        catch { lastFailure = .power; throw error }
    }
    public func setOptions(id: UUID, enabled: Bool, keepAwake: Bool) async throws {
        try await scheduler.setOptions(id: id, enabled: enabled, keepAwake: keepAwake)
        if running { try await self.keepAwake.refresh() }
    }
    public func cancel(id: UUID) async throws {
        try await scheduler.cancel(id: id)
        if running { try await keepAwake.refresh() }
    }
    public func profilesChanged() async throws {
        guard running else { return }
        try await keepAwake.refresh()
        try await scheduler.wake()
    }
    public func updates() async -> AsyncStream<Void> { await scheduler.updates() }
    public func setRowOption(failedInputID: UUID, _ option: AgentAutoContinueRowOption) async throws {
        guard running else { throw AgentFailure.invalidTransition }
        try await scheduler.setRowOption(failedInputID: failedInputID, option)
        if running { try await keepAwake.refresh() }
    }
    public func prepareForTermination() async throws {
        running = false; generation = UUID(); listener?.cancel(); listener = nil
        await scheduler.shutdown()
        do { try await keepAwake.shutdown() }
        catch { lastFailure = .power; throw error }
    }
    public func terminationCancelled(power: AgentAutoContinuePower) async throws {
        await manager.resumeAfterCancelledTermination()
        try await launch(power: power)
    }
    private func current(_ generation: UUID) -> Bool { running && self.generation == generation }
    private func schedulingChanged(_ generation: UUID) async {
        guard current(generation) else { return }
        do { try await keepAwake.refresh() }
        catch { lastFailure = .power }
    }
}
