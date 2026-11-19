import AitvarasAgents

/// The IOKit subscription lives in the package so SwiftPM compiles its C bindings.
@MainActor final class AgentAutoContinuePowerObserver {
    private let observation = AgentAutoContinuePowerObservation()
    func start(_ changed: @escaping @MainActor @Sendable (AgentAutoContinuePower) -> Void) {
        observation.start(changed)
    }
    func stop() { observation.stop() }
}
