import AitvarasAgents

extension AppModel {
    func startAutoContinuePowerObservation() {
        agentAutoContinuePowerObserver?.start { [weak self] power in
            guard let lifecycle = self?.agentAutoContinueLifecycle else { return }
            Task { try? await lifecycle.powerChanged(power) }
        }
    }
    func stopAutoContinuePowerObservation() { agentAutoContinuePowerObserver?.stop() }

    func noteAutoContinueWake() {
        guard let lifecycle = agentAutoContinueLifecycle else { return }
        let power = SystemPowerState.autoContinuePower()
        Task { try? await lifecycle.didWake(power: power) }
    }
    func resumeAgentChatsAfterCancelledTermination() async {
        chatModel?.resumeAfterCancelledTermination()
        if let lifecycle = agentAutoContinueLifecycle {
            let power = SystemPowerState.autoContinuePower()
            try? await lifecycle.terminationCancelled(power: power)
        } else { await agentSessionManager?.resumeAfterCancelledTermination() }
        startAutoContinuePowerObservation()
    }
}
