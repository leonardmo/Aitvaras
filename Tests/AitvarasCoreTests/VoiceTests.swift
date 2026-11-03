import Synchronization
import Foundation
import Testing
@testable import AitvarasVoice

private final class BlockingSpeechSynthesizer: SpeechSynthesizing, @unchecked Sendable {
    var amplitudeHandler: (@Sendable (Float) -> Void)?

    private struct State {
        var spoken: [String] = []
        var pending: CheckedContinuation<Void, Never>?
    }
    private let state = Mutex(State())

    func speak(_ text: String, languageCode: String?) async {
        await withCheckedContinuation { continuation in
            state.withLock {
                $0.spoken.append(text)
                $0.pending = continuation
            }
        }
    }

    func stop() {
        let continuation = state.withLock { state in
            let pending = state.pending
            state.pending = nil
            return pending
        }
        continuation?.resume()
    }

    func waitUntilSpeaking() async -> Bool {
        for _ in 0..<200 {
            if state.withLock({ !$0.spoken.isEmpty }) { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    var spoken: [String] { state.withLock { $0.spoken } }
}

private final class RecordingSpeechSynthesizer: SpeechSynthesizing, @unchecked Sendable {
    var amplitudeHandler: (@Sendable (Float) -> Void)?
    private let recorded = Mutex<[String]>([])

    func speak(_ text: String, languageCode: String?) async {
        recorded.withLock { $0.append(text) }
    }

    func stop() {}

    func waitForCount(_ count: Int) async -> Bool {
        for _ in 0..<200 {
            if recorded.withLock({ $0.count >= count }) { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    var spoken: [String] { recorded.withLock { $0 } }
}

@Suite struct VoiceTests {
    @Test func slowVoiceStateSubscriberKeepsOnlyLatestSnapshot() async {
        let pair = ConversationController.makeStateStream()
        var listening = VoiceSnapshot()
        listening.phase = .listening
        listening.userPartial = "old partial"
        var speaking = VoiceSnapshot()
        speaking.phase = .speaking
        speaking.assistantText = "latest answer"

        _ = pair.continuation.yield(listening)
        _ = pair.continuation.yield(speaking)
        pair.continuation.finish()

        var iterator = pair.stream.makeAsyncIterator()
        let latest = await iterator.next()
        let end = await iterator.next()
        #expect(latest == speaking)
        #expect(end == nil)
    }

    @Test func voiceDiagnosticsRedactPathsCredentialsAndLongPayloads() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let raw = "path=\(home)/private-note token: top-secret " + String(repeating: "x", count: 3_000)
        let sanitized = VoiceLog.sanitized(raw)

        #expect(!sanitized.contains(home))
        #expect(!sanitized.contains("top-secret"))
        #expect(sanitized.contains("<private-path>"))
        #expect(sanitized.contains("token=<redacted>"))
        #expect(sanitized.count < 2_100)
    }

    @Test func playbackTrackerWaitsForEveryScheduledBuffer() async {
        let tracker = PlaybackTracker()
        let finished = Mutex(false)
        tracker.willSchedule()
        tracker.willSchedule()
        let waiter = Task {
            await tracker.waitUntilDrained()
            finished.withLock { $0 = true }
        }

        try? await Task.sleep(for: .milliseconds(10))
        #expect(!finished.withLock { $0 })
        tracker.didFinishOne()
        try? await Task.sleep(for: .milliseconds(10))
        #expect(!finished.withLock { $0 })
        tracker.didFinishOne()
        await waiter.value
        #expect(finished.withLock { $0 })
    }

    @Test func playbackTrackerAbandonUnblocksDrain() async {
        let tracker = PlaybackTracker()
        tracker.willSchedule()
        let waiter = Task { await tracker.waitUntilDrained() }
        try? await Task.sleep(for: .milliseconds(10))
        tracker.abandon()
        await waiter.value
    }

    @Test func serverScriptDigestMatchesFileBytes() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aitvaras-tts-digest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("hello".utf8).write(to: url)

        #expect(NeuralTTS.serverScriptDigest(at: url)
            == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }

    @Test func staleVoiceCleanupMatchesOnlyAitvarasServerOnExactPort() {
        #expect(NeuralTTS.isAitvarasSidecarCommand(
            "/python /private/app/Resources/tts_server.py --port 8756", port: 8756))
        #expect(!NeuralTTS.isAitvarasSidecarCommand(
            "/python /private/app/Resources/tts_server.py --port 9000", port: 8756))
        #expect(!NeuralTTS.isAitvarasSidecarCommand(
            "/python /some/other_server.py --port 8756", port: 8756))
    }

    @Test func voiceEnvironmentAcceptsCurrentAndLegacyInstallMarkers() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aitvaras-voice-marker-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        #expect(!NeuralTTS.isReadyVenv(at: root))
        try Data().write(to: root.appendingPathComponent(".naomi-ready"))
        #expect(NeuralTTS.isReadyVenv(at: root))
        try FileManager.default.removeItem(at: root.appendingPathComponent(".naomi-ready"))
        try Data().write(to: root.appendingPathComponent(".aitvaras-ready"))
        #expect(NeuralTTS.isReadyVenv(at: root))
    }

    @Test func privateVoiceInstallRunsOfflineWithoutGlobalCredentials() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aitvaras-private-voice-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        #expect(NeuralTTS.privateServerEnvironment(at: root) == nil)
        try Data().write(to: root.appendingPathComponent(NeuralTTS.privateCacheMarker))
        let environment = try #require(NeuralTTS.privateServerEnvironment(at: root))

        #expect(environment["HF_HUB_OFFLINE"] == "1")
        #expect(environment["HF_HUB_DISABLE_IMPLICIT_TOKEN"] == "1")
        #expect(environment["HF_HOME"] == root.appendingPathComponent("hf-cache").path)
        #expect(environment["HOME"] == root.appendingPathComponent("sandbox-home").path)
        #expect(environment["HF_TOKEN"] == nil)
        #expect(environment["PATH"] != nil)
    }

    @Test func privateVoiceInstallerDoesNotInheritGlobalTokensOrCaches() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aitvaras-voice-install-env")
        let environment = NeuralTTS.privateInstallEnvironment(at: root)

        #expect(environment["HF_HUB_DISABLE_TELEMETRY"] == "1")
        #expect(environment["HF_HUB_DISABLE_IMPLICIT_TOKEN"] == "1")
        #expect(environment["HF_TOKEN"] == nil)
        #expect(environment["HF_HOME"] == root.appendingPathComponent("hf-cache").path)
        #expect(environment["HOME"] != FileManager.default.homeDirectoryForCurrentUser.path)
    }

    @Test func neuralSidecarShutdownEscalatesWithoutHanging() throws {
        let ready = FileManager.default.temporaryDirectory
            .appendingPathComponent("aitvaras-stubborn-process-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: ready) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Ignored signals survive exec(), giving the SIGKILL path a real test
        // without leaving an extra child process behind.
        process.arguments = [
            "-c", "trap '' TERM; : > \"$READY_FILE\"; exec /bin/sleep 60"
        ]
        process.environment = ["READY_FILE": ready.path]
        try process.run()
        defer { NeuralTTS.stopProcess(process, gracePeriod: 0.01) }
        let readyDeadline = Date.now.addingTimeInterval(1)
        while !FileManager.default.fileExists(atPath: ready.path), Date.now < readyDeadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        #expect(FileManager.default.fileExists(atPath: ready.path))

        let start = Date.now
        NeuralTTS.stopProcess(process, gracePeriod: 0.05)

        #expect(!process.isRunning)
        #expect(Date.now.timeIntervalSince(start) < 0.5)
    }

    @Test func stoppingAnnouncementPreventsQueuedSentencesFromResuming() async {
        let tts = BlockingSpeechSynthesizer()
        let controller = ConversationController(
            locale: { Locale(identifier: "en-US") },
            tts: tts,
            respond: { _, _ in AsyncStream { $0.finish() } })
        let announcement = Task {
            await controller.announce("First sentence. Second sentence.")
        }

        #expect(await tts.waitUntilSpeaking())
        await controller.stop()
        await announcement.value

        #expect(tts.spoken == ["First sentence."])
    }

    @Test func completedTurnDoesNotBlockLaterAnnouncement() async {
        let tts = RecordingSpeechSynthesizer()
        let controller = ConversationController(
            locale: { Locale(identifier: "en-US") },
            tts: tts,
            respond: { _, _ in
                AsyncStream { continuation in
                    continuation.yield(.delta("Reply finished."))
                    continuation.yield(.done)
                    continuation.finish()
                }
            })

        await controller.submitTyped("Hello")
        #expect(await tts.waitForCount(1))
        await controller.announce("Proactive update.")

        #expect(await tts.waitForCount(2))
        #expect(tts.spoken == ["Reply finished.", "Proactive update."])
    }

    @Test func deterministicVoiceReplyNeverPresentsModelThinking() async {
        let tts = RecordingSpeechSynthesizer()
        let controller = ConversationController(
            locale: { Locale(identifier: "en-US") },
            tts: tts,
            respond: { _, _ in
                AsyncStream { continuation in
                    continuation.yield(.delta("Shortcut used."))
                    continuation.yield(.done)
                    continuation.finish()
                }
            })
        let states = await controller.states()
        let observed = Mutex<[VoicePhase]>([])
        let observer = Task {
            for await snapshot in states {
                observed.withLock { $0.append(snapshot.phase) }
                if snapshot.phase == .idle,
                   observed.withLock({ $0.contains(.speaking) }) { break }
            }
        }

        await controller.submitTyped("Stop, Licht aus")
        #expect(await tts.waitForCount(1))
        _ = await observer.value

        #expect(!observed.withLock { $0.contains(.thinking) })
        #expect(observed.withLock { $0.contains(.routing) })
        #expect(observed.withLock { $0.contains(.speaking) })
    }

    @Test func announcementDuringTurnIsQueuedInsteadOfLost() async {
        let tts = BlockingSpeechSynthesizer()
        let controller = ConversationController(
            locale: { Locale(identifier: "en-US") },
            tts: tts,
            respond: { _, _ in
                AsyncStream { continuation in
                    continuation.yield(.delta("The user reply is complete."))
                    continuation.yield(.done)
                    continuation.finish()
                }
            })

        await controller.submitTyped("Hello")
        #expect(await tts.waitUntilSpeaking())
        await controller.announce("An urgent update arrived.")
        #expect(tts.spoken == ["The user reply is complete."])

        tts.stop()
        for _ in 0..<200 where tts.spoken.count < 2 {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(tts.spoken == [
            "The user reply is complete.",
            "An urgent update arrived."
        ])
        tts.stop()
    }
}
