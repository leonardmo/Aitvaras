import Foundation
import Synchronization

/// Bounds a framework operation even if its cancellation is non-cooperative.
/// Unlike a task-group race, returning does not wait for the losing task to
/// acknowledge cancellation. Use only where the caller can quarantine late
/// results; a timeout never proves that an underlying side effect stopped.
public enum AsyncDeadline {
    public struct Exceeded: Error, Sendable, Equatable {
        public init() {}
    }

    public static func run<Value: Sendable>(
        for timeout: Duration,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let gate = DeadlineGate<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard gate.install(continuation) else { return }
                let work = Task {
                    do {
                        try Task.checkCancellation()
                        gate.resolve(.success(try await operation()))
                    }
                    catch { gate.resolve(.failure(error)) }
                }
                gate.attach(work)
                let timer = Task {
                    do {
                        try await Task.sleep(for: timeout)
                        gate.resolve(.failure(Exceeded()))
                    } catch { /* Work finished or caller cancelled. */ }
                }
                gate.attach(timer)
            }
        } onCancel: {
            gate.resolve(.failure(CancellationError()))
        }
    }
}

private final class DeadlineGate<Value: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Value, any Error>?
        var result: Result<Value, any Error>?
        var tasks: [Task<Void, Never>] = []
    }
    private let state = Mutex(State())

    func install(_ continuation: CheckedContinuation<Value, any Error>) -> Bool {
        let result = state.withLock { state -> Result<Value, any Error>? in
            if let result = state.result { return result }
            state.continuation = continuation
            return nil as Result<Value, any Error>?
        }
        if let result { continuation.resume(with: result); return false }
        return true
    }

    func attach(_ task: Task<Void, Never>) {
        let cancel = state.withLock { state in
            guard state.result == nil else { return true }
            state.tasks.append(task)
            return false
        }
        if cancel { task.cancel() }
    }

    func resolve(_ result: Result<Value, any Error>) {
        let finished = state.withLock { state -> (CheckedContinuation<Value, any Error>?, [Task<Void, Never>]) in
            guard state.result == nil else { return (nil, []) }
            state.result = result
            let continuation = state.continuation
            state.continuation = nil
            let tasks = state.tasks
            state.tasks = []
            return (continuation, tasks)
        }
        for task in finished.1 { task.cancel() }
        finished.0?.resume(with: result)
    }
}
