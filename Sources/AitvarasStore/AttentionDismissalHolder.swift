import Foundation
import Observation

/// AppModel owns one holder. Only the latest nonempty receipt is offered for
/// Undo; durable mutations and their cleanup remain in Stores.
@MainActor @Observable
public final class AttentionDismissalHolder {
    public private(set) var receipt: AttentionDismissalReceipt?
    public private(set) var monitoringError: String?
    public private(set) var monitoringIncidentID: UUID?
    private var hiddenByReceiptID: UUID?
    @ObservationIgnored private let clock: AttentionUndoClock
    @ObservationIgnored private var expiryTask: Task<Void, Never>?

    public init(clock: AttentionUndoClock = .continuous) { self.clock = clock }

    deinit { expiryTask?.cancel() }

    public var canUndo: Bool {
        if let receipt { return clock.now() < receipt.deadline }
        return false
    }

    public var visibleMonitoringError: String? {
        hiddenByReceiptID == nil ? monitoringError : nil
    }

    /// Repeated refreshes of the same error retain the current incident. A
    /// recovery or different error ends it, invalidating its old hide proof.
    public func updateMonitoringError(_ error: String?) {
        guard error != monitoringError else { return }
        monitoringError = error
        monitoringIncidentID = error == nil ? nil : UUID()
        hiddenByReceiptID = nil
    }

    @discardableResult
    public func hideMonitoringIncident(using stores: Stores) throws -> AttentionDismissalReceipt? {
        guard let incident = monitoringIncidentID, hiddenByReceiptID == nil else { return nil }
        let receipt = try stores.dismissMonitoringIncident(id: incident)
        hiddenByReceiptID = receipt.monitoring?.writtenHiddenByReceiptID
        present(receipt)
        return receipt
    }

    /// A duplicate/no-op click must not discard an existing useful Undo.
    public func present(_ receipt: AttentionDismissalReceipt) {
        guard !receipt.isEmpty else { return }
        expiryTask?.cancel()
        self.receipt = nil
        guard clock.now() < receipt.deadline else { return }
        self.receipt = receipt
        let clock = clock
        expiryTask = Task { [weak self] in
            do {
                try await clock.sleepUntil(receipt.deadline)
                guard !Task.isCancelled else { return }
                self?.expireIfNeeded()
            } catch { /* A newer receipt cancels this deadline. */ }
        }
    }

    /// Also callable on foreground/wake, or after advancing an injected clock.
    public func expireIfNeeded() {
        guard let receipt, clock.now() >= receipt.deadline else { return }
        self.receipt = nil
        expiryTask?.cancel()
        expiryTask = nil
    }

    @discardableResult
    public func undo(using stores: Stores) throws -> AttentionUndoResult? {
        expireIfNeeded()
        guard let receipt else { return nil }
        let incident = receipt.monitoring.flatMap { change in
            hiddenByReceiptID == change.writtenHiddenByReceiptID && monitoringIncidentID == change.incidentID
                ? change.incidentID : nil
        }
        let result = try stores.undoAttentionDismissal(receipt, monitoringIncidentID: incident)
        if result.monitoringIncidentID == monitoringIncidentID, incident != nil {
            hiddenByReceiptID = receipt.monitoring?.previousHiddenByReceiptID
        }
        self.receipt = nil
        expiryTask?.cancel()
        expiryTask = nil
        return result
    }
}
