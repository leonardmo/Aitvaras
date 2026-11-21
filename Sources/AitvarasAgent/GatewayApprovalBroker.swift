import Foundation
import AitvarasAgents
import AitvarasCore

public struct GatewayApprovalRequest: Sendable, Identifiable {
    public let id: UUID
    public let invocation: MCPGatewayInvocation
    public let toolName: String
    public let risk: ActionRisk
    /// Transient card data. This type deliberately has no persistence encoding.
    public let arguments: JSONValue
}

/// App presentation consumes pending requests and resolves their one-shot IDs.
/// Inline requests use the native chat lifecycle rather than the outside timer.
public actor GatewayApprovalBroker {
    enum Outcome: String, Sendable { case approved, denied, timedOut, cancelled }
    private struct Pending {
        let request: GatewayApprovalRequest
        let continuation: CheckedContinuation<Outcome, Never>
        let deadline: ContinuousClock.Instant?
        let timer: Task<Void, Never>?
    }

    private let outsideTimeout: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private let sleepUntil: @Sendable (ContinuousClock.Instant) async throws -> Void
    private var pending: [UUID: Pending] = [:]
    public nonisolated let changes: AsyncStream<Void>
    private let changesContinuation: AsyncStream<Void>.Continuation

    public init() { self.init(outsideTimeout: .seconds(300)) }

    init(outsideTimeout: Duration,
         now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
         sleepUntil: @escaping @Sendable (ContinuousClock.Instant) async throws -> Void = {
             try await ContinuousClock().sleep(until: $0)
         }) {
        self.outsideTimeout = outsideTimeout
        self.now = now
        self.sleepUntil = sleepUntil
        (changes, changesContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    deinit {
        for entry in pending.values {
            entry.timer?.cancel()
            entry.continuation.resume(returning: .cancelled)
        }
        changesContinuation.finish()
    }

    public func requests() -> [GatewayApprovalRequest] {
        pending.values.map(\.request).sorted { $0.id.uuidString < $1.id.uuidString }
    }

    func wait(for request: GatewayApprovalRequest) async -> Outcome {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, pending[request.id] == nil, pending.count < 64 else {
                    continuation.resume(returning: .cancelled)
                    return
                }
                let deadline = request.invocation.presentation == .outside
                    ? now().advanced(by: outsideTimeout) : nil
                let sleep = sleepUntil
                let timer = deadline.map { deadline in
                    Task { [weak self] in
                        do { try await sleep(deadline) }
                        catch { return }
                        await self?.resolve(request.id, as: .timedOut)
                    }
                }
                pending[request.id] = .init(request: request, continuation: continuation, deadline: deadline, timer: timer)
                changesContinuation.yield()
            }
        } onCancel: {
            Task { await self.resolve(request.id, as: .cancelled) }
        }
    }

    @discardableResult
    public func decide(id: UUID, allow: Bool) -> Bool {
        guard let entry = pending[id] else { return false }
        if let deadline = entry.deadline, now() >= deadline {
            resolve(id, as: .timedOut)
            return false
        }
        resolve(id, as: allow ? .approved : .denied)
        return true
    }

    public func cancel(launchID: UUID) {
        let ids = pending.values.filter { $0.request.invocation.launchID == launchID }.map(\.request.id)
        for id in ids { resolve(id, as: .cancelled) }
    }

    private func resolve(_ id: UUID, as outcome: Outcome) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.timer?.cancel()
        entry.continuation.resume(returning: outcome)
        changesContinuation.yield()
    }
}
