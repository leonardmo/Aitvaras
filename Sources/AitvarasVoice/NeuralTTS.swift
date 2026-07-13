import Foundation
@preconcurrency import AVFoundation
import AitvarasCore
import Synchronization

/// Chatterbox Multilingual via a local Python sidecar (D3) — the
/// "ChatGPT voice mode" quality tier, German + English. Falls back to
/// AppleTTS transparently whenever the sidecar isn't installed/healthy.
public final class NeuralTTS: @unchecked Sendable {
    public var amplitudeHandler: (@Sendable (Float) -> Void)? {
        didSet { fallback.amplitudeHandler = amplitudeHandler }
    }

    private let fallback = AppleTTS()
    private let port: Int
    private let serverScriptURL: URL?
    private let session: URLSession

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var engineStarted = false
    private let cancelled = Mutex(false)
    private var serverProcess: Process?
    private let serverState = Mutex("stopped")   // stopped | starting | ready | failed
    private var inflight: URLSessionDataTask?

    public static func venvURL() -> URL {
        // The venv is heavyweight and profile-independent like the models —
        // it deliberately stays in the DEFAULT state dir even for isolated
        // profiles, so test profiles don't trigger a multi-GB reinstall.
        AitvarasPaths.defaultStateDirectory.appendingPathComponent("voice-venv")
    }

    /// Installed = setup script completed (venv + cached weights).
    public static func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: venvURL().appendingPathComponent(".aitvaras-ready").path)
    }

    public init(serverScriptURL: URL?, port: Int = 8756) {
        self.serverScriptURL = serverScriptURL
        self.port = port
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        self.session = URLSession(configuration: config)
    }

    // MARK: Sidecar lifecycle

    private var healthURL: URL { URL(string: "http://127.0.0.1:\(port)/health")! }
    private var ttsURL: URL { URL(string: "http://127.0.0.1:\(port)/tts")! }

    /// Server generation this build requires. A healthy-but-older
    /// sidecar (left over from a previous app version — children outlive
    /// their parent) is killed and respawned.
    private static let requiredServerVersion = 2

    private func isHealthy() async -> Bool {
        var request = URLRequest(url: healthURL)
        request.timeoutInterval = 2
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["version"] as? Int == Self.requiredServerVersion else {
            VoiceLog.log("tts: stale sidecar detected — killing it")
            Self.killStraySidecars()
            return false
        }
        return true
    }

    /// Kill sidecars from previous app instances (they are not our
    /// children, so Process bookkeeping doesn't know them).
    public static func killStraySidecars() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        task.arguments = ["-f", "Resources/tts_server.py"]
        try? task.run()
        task.waitUntilExit()
    }

    /// Start the sidecar if needed; true when ready. Model load takes
    /// ~30–90s on first start, so the first sentence may fall back.
    public func ensureServer() async -> Bool {
        if await isHealthy() {
            serverState.withLock { $0 = "ready" }
            return true
        }
        guard Self.isInstalled(), let serverScriptURL else { return false }
        let shouldStart = serverState.withLock { state -> Bool in
            if state == "starting" { return false }
            state = "starting"
            return true
        }
        if shouldStart {
            let process = Process()
            process.executableURL = Self.venvURL().appendingPathComponent("bin/python")
            process.arguments = [serverScriptURL.path, "--port", String(port)]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                serverProcess = process
            } catch {
                serverState.withLock { $0 = "failed" }
                return false
            }
        }
        for _ in 0..<45 {   // up to ~90s for model load
            try? await Task.sleep(for: .seconds(2))
            if await isHealthy() {
                serverState.withLock { $0 = "ready" }
                return true
            }
            if let serverProcess, !serverProcess.isRunning {
                serverState.withLock { $0 = "failed" }
                return false
            }
        }
        serverState.withLock { $0 = "failed" }
        return false
    }

    public func shutdownServer() {
        serverProcess?.terminate()
        serverProcess = nil
        serverState.withLock { $0 = "stopped" }
    }

    // MARK: Speaking

    /// Aitvaras speaks with ONE voice: Kokoro (user decision 2026-07-06 —
    /// "always use this kokoro model, never switch to the german tts").
    /// The agent answers in English regardless of input language; Apple
    /// voices remain only as emergency fallback when the sidecar is down.
    public func speak(_ text: String, languageCode: String? = nil) async {
        cancelled.withLock { $0 = false }
        let language = "en"
        _ = languageCode
        // Sidecar not ready → Apple voices rather than silence.
        let ready: Bool
        if serverState.withLock({ $0 }) == "ready" {
            ready = true
        } else {
            ready = await ensureServer()
        }
        guard ready else {
            await fallback.speak(text, languageCode: language)
            return
        }

        var request = URLRequest(url: ttsURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "text": text, "language": language
        ])

        let wavData: Data
        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                await fallback.speak(text, languageCode: language)
                return
            }
            wavData = data
        } catch {
            await fallback.speak(text, languageCode: language)
            return
        }

        if cancelled.withLock({ $0 }) { return }
        await play(wavData: wavData)
        amplitudeHandler?(0)
    }

    public func stop() {
        cancelled.withLock { $0 = true }
        inflight?.cancel()
        player.stop()
        fallback.stop()
        amplitudeHandler?(0)
    }

    private func play(wavData: Data) async {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("aitvaras-tts-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try wavData.write(to: tmp)
            let file = try AVAudioFile(forReading: tmp)
            let format = file.processingFormat
            startEngineIfNeeded(format: format)

            let tracker = PlaybackTracker()
            let amplitude = amplitudeHandler
            let chunkFrames: AVAudioFrameCount = 4096

            while file.framePosition < file.length {
                if cancelled.withLock({ $0 }) { tracker.abandon(); return }
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else { break }
                try file.read(into: buffer, frameCount: chunkFrames)
                if buffer.frameLength == 0 { break }
                VoiceVolume.apply(to: buffer)
                tracker.willSchedule()
                let level = AppleTTS.energy(of: buffer)
                player.scheduleBuffer(buffer) {
                    amplitude?(level)
                    tracker.didFinishOne()
                }
            }
            if cancelled.withLock({ $0 }) {
                tracker.abandon()
            } else {
                await tracker.waitUntilDrained()
            }
        } catch {
            // Corrupt audio — nothing to play.
        }
    }

    private func startEngineIfNeeded(format: AVAudioFormat) {
        if !engineStarted {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            engine.prepare()
            engineStarted = true
        }
        // Re-arm after stop() — a stopped player node never plays newly
        // scheduled buffers (see AppleTTS.startEngineIfNeeded).
        if !engine.isRunning { try? engine.start() }
        if !player.isPlaying { player.play() }
    }
}

extension NeuralTTS: SpeechSynthesizing {}
