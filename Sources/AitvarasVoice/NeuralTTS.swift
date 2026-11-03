import Foundation
import CryptoKit
import Darwin
@preconcurrency import AVFoundation
import AitvarasCore
import Synchronization

/// Chatterbox Multilingual via a local Python sidecar (D3) — the
/// "ChatGPT voice mode" quality tier, German + English. Falls back to
/// AppleTTS transparently whenever the sidecar isn't installed/healthy.
public final class NeuralTTS: @unchecked Sendable {
    static let privateCacheMarker = ".aitvaras-private-cache-ready"
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
    private let generation = Mutex<UInt64>(0)
    private let serverProcess = Mutex<Process?>(nil)
    private let serverState = Mutex("stopped")   // stopped | starting | ready | failed

    public static func venvURL() -> URL {
        // The venv is heavyweight and profile-independent like the models —
        // it deliberately stays in the DEFAULT state dir even for isolated
        // profiles, so test profiles don't trigger a multi-GB reinstall.
        let current = AitvarasPaths.defaultStateDirectory.appendingPathComponent("voice-venv")
        if isReadyVenv(at: current) { return current }
        let legacy = AitvarasPaths.legacyStateDirectory.appendingPathComponent("voice-venv")
        return isReadyVenv(at: legacy) ? legacy : current
    }

    /// Installed = setup script completed (venv + cached weights).
    public static func isInstalled() -> Bool {
        isReadyVenv(at: venvURL())
    }

    static func isReadyVenv(at url: URL) -> Bool {
        [".aitvaras-ready", ".naomi-ready", privateCacheMarker].contains { marker in
            FileManager.default.fileExists(atPath: url.appendingPathComponent(marker).path)
        }
    }

    /// New installs never inspect the user's global Python/Hugging Face
    /// configuration and run offline after setup. Legacy installations keep
    /// their previous environment so existing multi-GB caches still work.
    static func privateServerEnvironment(at venv: URL) -> [String: String]? {
        guard FileManager.default.fileExists(
            atPath: venv.appendingPathComponent(privateCacheMarker).path) else { return nil }
        return [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": venv.appendingPathComponent("sandbox-home").path,
            "HF_HOME": venv.appendingPathComponent("hf-cache").path,
            "TMPDIR": FileManager.default.temporaryDirectory.path,
            "LANG": "en_US.UTF-8",
            "HF_HUB_OFFLINE": "1",
            "HF_HUB_DISABLE_TELEMETRY": "1",
            "HF_HUB_DISABLE_IMPLICIT_TOKEN": "1",
            "PYTHONNOUSERSITE": "1"
        ]
    }

    public static func privateInstallEnvironment(at venv: URL) -> [String: String] {
        let parent = venv.deletingLastPathComponent()
        return [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": parent.appendingPathComponent("voice-install-home").path,
            "HF_HOME": venv.appendingPathComponent("hf-cache").path,
            "TMPDIR": FileManager.default.temporaryDirectory.path,
            "LANG": "en_US.UTF-8",
            "HF_HUB_DISABLE_TELEMETRY": "1",
            "HF_HUB_DISABLE_IMPLICIT_TOKEN": "1",
            "PIP_DISABLE_PIP_VERSION_CHECK": "1",
            "PIP_NO_CACHE_DIR": "1",
            "PYTHONNOUSERSITE": "1"
        ]
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
    private static let requiredServerVersion = 4

    static func serverScriptDigest(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func isHealthy() async -> Bool {
        var request = URLRequest(url: healthURL)
        request.timeoutInterval = 2
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
        guard let serverScriptURL,
              let expectedDigest = Self.serverScriptDigest(at: serverScriptURL) else {
            return false
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["version"] as? Int == Self.requiredServerVersion,
              json["scriptSHA256"] as? String == expectedDigest else {
            VoiceLog.log("tts: incompatible service detected on voice port")
            stopOwnedServer()
            await stopUnownedServerIfItIsAitvaras()
            return false
        }
        return true
    }

    /// Stop only the Aitvaras sidecar listening on this instance's port.
    /// A global `pkill -f tts_server.py` can terminate another profile—or an
    /// unrelated developer process—so discover the listener and verify its
    /// complete command first.
    private func stopUnownedServerIfItIsAitvaras() async {
        guard let listeners = try? await DisclaimedProcess.run(
            executable: "/usr/sbin/lsof",
            arguments: ["-nP", "-t", "-iTCP:\(port)", "-sTCP:LISTEN"],
            timeout: 2,
            inheritEnvironment: false) else { return }
        let pids = listeners.stdout.split(whereSeparator: \.isWhitespace)
            .compactMap { pid_t(String($0)) }
        for pid in pids where pid > 1 {
            if serverProcess.withLock({ $0?.processIdentifier == pid }) { continue }
            guard let result = try? await DisclaimedProcess.run(
                executable: "/bin/ps",
                arguments: ["-p", String(pid), "-o", "command="],
                timeout: 2,
                inheritEnvironment: false),
                  Self.isAitvarasSidecarCommand(result.stdout, port: port) else { continue }
            _ = Darwin.kill(pid, SIGTERM)
            try? await Task.sleep(for: .milliseconds(250))
            if Darwin.kill(pid, 0) == 0 { _ = Darwin.kill(pid, SIGKILL) }
        }
    }

    /// Lightweight startup recovery: a crash can leave Python alive after
    /// the app disappears. Reap only a verified Aitvaras listener on our
    /// exact port; do not load models or start a replacement.
    public func cleanupUnownedServer() async {
        await stopUnownedServerIfItIsAitvaras()
    }

    static func isAitvarasSidecarCommand(_ command: String, port: Int) -> Bool {
        command.contains("tts_server.py")
            && command.contains("--port \(port)")
    }

    /// Start the sidecar if needed; true when ready. Model load takes
    /// ~30–90s on first start, so the first sentence may fall back.
    public func ensureServer() async -> Bool {
        if await isHealthy() {
            if serverProcess.withLock({ $0?.isRunning == true }) {
                serverState.withLock { $0 = "ready" }
                return true
            }
            // A matching server without our Process handle survived another
            // app instance. Replace it so this instance owns—and can stop—it.
            VoiceLog.log("tts: replacing unowned sidecar")
            await stopUnownedServerIfItIsAitvaras()
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard Self.isInstalled(), let serverScriptURL else { return false }
        let shouldStart = serverState.withLock { state -> Bool in
            if state == "starting" { return false }
            state = "starting"
            return true
        }
        if shouldStart {
            let process = Process()
            let venv = Self.venvURL()
            process.executableURL = venv.appendingPathComponent("bin/python")
            process.arguments = [serverScriptURL.path, "--port", String(port)]
            if let environment = Self.privateServerEnvironment(at: venv) {
                process.environment = environment
            }
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                serverProcess.withLock { $0 = process }
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
            if serverProcess.withLock({ $0?.isRunning == false }) {
                stopOwnedServer()
                serverState.withLock { $0 = "failed" }
                return false
            }
        }
        stopOwnedServer()
        serverState.withLock { $0 = "failed" }
        return false
    }

    public func shutdownServer() {
        stopOwnedServer()
        serverState.withLock { $0 = "stopped" }
    }

    private func stopOwnedServer() {
        let process = serverProcess.withLock { current in
            let process = current
            current = nil
            return process
        }
        if let process { Self.stopProcess(process) }
    }

    /// Synchronous because app termination calls it, but strictly bounded:
    /// a sidecar that ignores SIGTERM must never keep Aitvaras from quitting.
    static func stopProcess(_ process: Process, gracePeriod: TimeInterval = 1) {
        guard process.isRunning else { return }
        process.terminate()
        guard !waitForExit(process, timeout: gracePeriod) else { return }
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
        _ = waitForExit(process, timeout: 0.25)
    }

    @discardableResult
    private static func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date.now.addingTimeInterval(max(0, timeout))
        while process.isRunning, Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        return !process.isRunning
    }

    // MARK: Speaking

    /// Aitvaras speaks with ONE voice: Kokoro (user decision 2026-07-06 —
    /// "always use this kokoro model, never switch to the german tts").
    /// The agent answers in English regardless of input language; Apple
    /// voices remain only as emergency fallback when the sidecar is down.
    public func speak(_ text: String, languageCode: String? = nil) async {
        let speechGeneration = generation.withLock { value in
            value &+= 1
            return value
        }
        // Supersede any older player/fallback work before beginning a new
        // utterance. Its callbacks also carry their generation below.
        player.stop()
        fallback.stop()
        let language = "en"
        _ = languageCode
        // Do not launch a multi-gigabyte Python/model process at app startup
        // or make the first spoken sentence wait up to 90 seconds. The first
        // cold utterance uses the immediate Apple fallback while neural voice
        // warms in the background; following turns use it once ready.
        let state = serverState.withLock { $0 }
        guard state == "ready" else {
            if state != "starting", Self.isInstalled() {
                Task.detached(priority: .utility) { [weak self] in
                    _ = await self?.ensureServer()
                }
            }
            await fallback.speak(text, languageCode: language)
            return
        }
        guard isCurrent(speechGeneration) else { return }

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
                serverState.withLock { $0 = "failed" }
                await fallback.speak(text, languageCode: language)
                return
            }
            wavData = data
        } catch {
            serverState.withLock { $0 = "failed" }
            await fallback.speak(text, languageCode: language)
            return
        }

        guard isCurrent(speechGeneration) else { return }
        await play(wavData: wavData, generation: speechGeneration)
        if isCurrent(speechGeneration) { amplitudeHandler?(0) }
    }

    public func stop() {
        generation.withLock { $0 &+= 1 }
        player.stop()
        fallback.stop()
        amplitudeHandler?(0)
    }

    private func isCurrent(_ value: UInt64) -> Bool {
        generation.withLock { $0 == value }
    }

    private func play(wavData: Data, generation speechGeneration: UInt64) async {
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
                if !isCurrent(speechGeneration) { tracker.abandon(); return }
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else { break }
                try file.read(into: buffer, frameCount: chunkFrames)
                if buffer.frameLength == 0 { break }
                VoiceVolume.apply(to: buffer)
                tracker.willSchedule()
                let level = AppleTTS.energy(of: buffer)
                player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    if self?.isCurrent(speechGeneration) == true { amplitude?(level) }
                    tracker.didFinishOne()
                }
            }
            if !isCurrent(speechGeneration) {
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
