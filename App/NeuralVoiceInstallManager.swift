import Foundation
import Observation
import AitvarasCore
import AitvarasVoice
import AitvarasStore

/// App-lifetime, cancellable installation of the optional neural voice.
/// Partial package/model downloads remain in the private venv and resume on
/// Retry; termination waits until the helper process has been reaped.
@MainActor
@Observable
final class NeuralVoiceInstallManager {
    var reporter: ActivityReporter?
    private var activityID: UUID?
    private(set) var installed = NeuralTTS.isInstalled()
    private(set) var isInstalling = false
    private(set) var isCancelling = false
    private(set) var status = ""

    private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        guard let script = Bundle.main.url(
            forResource: "setup-neural-voice", withExtension: "sh") else {
            status = "Installer missing from the app bundle — rebuild Aitvaras."
            return
        }

        let venv = NeuralTTS.venvURL()
        do {
            try FileManager.default.createDirectory(
                at: venv.deletingLastPathComponent(), withIntermediateDirectories: true)
            let environment = NeuralTTS.privateInstallEnvironment(at: venv)
            if let home = environment["HOME"] {
                try FileManager.default.createDirectory(
                    at: URL(fileURLWithPath: home, isDirectory: true),
                    withIntermediateDirectories: true)
            }
        } catch {
            status = "Voice install could not prepare its private folder: \(error.localizedDescription)"
            return
        }

        isInstalling = true
        activityID = reporter?.begin(ActivityRun(category: .model, title: "Install optional voice",
            stage: "Installing pinned voice components", executionLocation: "This Mac",
            dataAccess: "Public voice packages and weights", dataDestination: "Package/model download hosts; no conversations"))
        isCancelling = false
        status = "Installing pinned voice engines and weights…"
        task = Task { [weak self] in
            do {
                let output = try await DisclaimedProcess.run(
                    executable: "/bin/zsh",
                    arguments: [script.path, venv.path],
                    timeout: 4 * 60 * 60,
                    environment: NeuralTTS.privateInstallEnvironment(at: venv),
                    inheritEnvironment: false)
                guard let self else { return }
                guard output.exitCode == 0, NeuralTTS.isInstalled() else {
                    status = "Install stopped (code \(output.exitCode)). \(Self.tail(output.stdout))"
                    finish(state: .failed)
                    return
                }
                installed = true
                status = "Installed ✓"
                finish(state: .succeeded)
            } catch is CancellationError {
                guard let self else { return }
                status = "Paused — Retry continues from saved files"
                finish(state: .cancelled)
            } catch {
                guard let self else { return }
                status = "Install failed: \(error.localizedDescription)"
                finish(state: .failed)
            }
        }
    }

    func cancelActive() {
        guard task != nil else { return }
        isCancelling = true
        if let activityID { reporter?.update(id: activityID, stage: "Stopping installer safely", state: .cancellationRequested) }
        status = "Pausing safely…"
        task?.cancel()
    }

    func stopBeforeTermination() async {
        guard let running = task else { return }
        cancelActive()
        await running.value
    }

    private func finish(state: ActivityRunState) {
        if let activityID { reporter?.finish(id: activityID, state: state,
            outcome: state == .succeeded ? "Voice installed" : state == .cancelled ? "Paused; partial files retained" : "Install failed; review Settings") }
        activityID = nil
        task = nil
        isInstalling = false
        isCancelling = false
    }

    private static func tail(_ output: String) -> String {
        let lines = output.split(separator: "\n").suffix(4).joined(separator: " ")
        return lines.isEmpty ? "Retry to continue." : String(lines.suffix(600))
    }
}
