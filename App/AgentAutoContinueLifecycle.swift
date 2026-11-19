import AitvarasAgents

extension AppModel {
    func startAutoContinuePowerObservation() {
        guard AgentAutoContinueLifecycle.productionArmingEnabled else { return }
        agentAutoContinuePowerObserver?.start { [weak self] power in
            guard let lifecycle = self?.agentAutoContinueLifecycle else { return }
            Task { try? await lifecycle.powerChanged(power) }
        }
    }
    func stopAutoContinuePowerObservation() { agentAutoContinuePowerObserver?.stop() }

    func noteAutoContinueWake() {
        guard AgentAutoContinueLifecycle.productionArmingEnabled, let lifecycle = agentAutoContinueLifecycle else { return }
        let power = SystemPowerState.autoContinuePower()
        Task { try? await lifecycle.didWake(power: power) }
    }
    func resumeAgentChatsAfterCancelledTermination() async {
        chatModel?.resumeAfterCancelledTermination()
        if let lifecycle = agentAutoContinueLifecycle {
            let power = AgentAutoContinueLifecycle.productionArmingEnabled ? SystemPowerState.autoContinuePower() : .unknown
            try? await lifecycle.terminationCancelled(power: power)
        } else { await agentSessionManager?.resumeAfterCancelledTermination() }
        startAutoContinuePowerObservation()
    }
}
