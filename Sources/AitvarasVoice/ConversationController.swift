import Foundation
@preconcurrency import AVFoundation
import AitvarasCore

public enum VoicePhase: String, Sendable {
    case idle, listening, thinking, speaking
}

/// UI-facing state of the voice conversation — drives both the voice
/// panel and the avatar's animation (D3, D4).
public struct VoiceSnapshot: Sendable, Equatable {
    public var phase: VoicePhase = .idle
    public var userPartial: String = ""
    public var assistantText: String = ""
    public var mouthLevel: Float = 0
    /// Transient state worth showing ("Loading speech model…").
    public var statusMessage: String?
    public var errorMessage: String?

    public init() {}
}

/// A reply stream element from the agent (adapter type so AitvarasVoice
/// doesn't depend on AitvarasAgent).
public enum VoiceReply: Sendable {
    case delta(String)
    case done
}

/// The hands-free conversation loop (D3): started manually, then
/// continuous — VAD end-of-turn via the transcriber's result cadence,
/// sentence-streamed TTS, barge-in by talking over her.
public actor ConversationController {
    private let respond: @Sendable ([ChatMessage], String) -> AsyncStream<VoiceReply>
    private let locale: @Sendable () -> Locale

    private let tts: any SpeechSynthesizing
    private var mic: MicCapture?
    private var transcriber: TranscriberSession?
    private var feedTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?
    private var turnTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?

    private var snapshot = VoiceSnapshot()
    private var stateContinuations: [UUID: AsyncStream<VoiceSnapshot>.Continuation] = [:]

    // End-of-turn detection state
    private var utterance = ""            // finalized text of the current user turn
    private var volatileTail = ""         // latest volatile (unstable) text
    private var lastResultAt: Date = .distantPast
    private var lastCommittedText = ""    // guards against the late FINAL echo
    private var lastInteractionAt: Date = .distantPast
    private var history: [ChatMessage] = []
    /// Re-checked whenever she starts speaking — headphones allow
    /// full-duplex barge-in, speakers force half-duplex.
    private var headphonesActive = false
    /// On speakers: results arriving shortly AFTER she finished speaking
    /// are still her own trailing echo — drop until this deadline.
    private var echoCooldownUntil: Date = .distantPast

    /// Listening with nothing happening for this long ends the session.
    private let idleTimeout: TimeInterval = 30

    /// Silence after the last (partial) result before we commit the turn.
    /// Below ~1.1s natural mid-sentence pauses cause premature commits
    /// (observed live: "Hi Naom" → commit → barge-in → recommit).
    private let endOfTurnSilence: TimeInterval = 1.2
    /// Volatile text length that triggers barge-in while she speaks.
    private let bargeInThreshold = 10

    public init(
        locale: @escaping @Sendable () -> Locale,
        tts: (any SpeechSynthesizing)? = nil,
        respond: @escaping @Sendable ([ChatMessage], String) -> AsyncStream<VoiceReply>
    ) {
        self.locale = locale
        self.tts = tts ?? AppleTTS()
        self.respond = respond
    }

    // MARK: State publishing

    public func states() -> AsyncStream<VoiceSnapshot> {
        AsyncStream { continuation in
            let id = UUID()
            stateContinuations[id] = continuation
            continuation.yield(snapshot)
            continuation.onTermination = { _ in
                Task { await self.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        stateContinuations[id] = nil
    }

    private func publish(_ mutate: (inout VoiceSnapshot) -> Void) {
        mutate(&snapshot)
        for continuation in stateContinuations.values {
            continuation.yield(snapshot)
        }
    }

    // MARK: Lifecycle

    public var isRunning: Bool { mic != nil }

    public func start() async {
        guard mic == nil else { return }
        VoiceLog.reset("voice session start, locale \(locale().identifier)")
        // Each session starts a fresh conversation — pressing the mic
        // again is a reset, not a resume.
        history.removeAll()
        lastCommittedText = ""
        utterance = ""
        volatileTail = ""
        lastInteractionAt = .now
        publish { $0 = VoiceSnapshot(); $0.phase = .listening; $0.statusMessage = "Starting…" }

        // Permissions first — otherwise everything below fails silently.
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                fail("Microphone access denied. Enable it in System Settings → Privacy & Security → Microphone.")
                publish { $0.phase = .idle; $0.statusMessage = nil }
                return
            }
        }
        if TranscriberSession.authorizationStatus() != .authorized {
            guard await TranscriberSession.requestAuthorization() else {
                fail("Speech recognition denied. Enable it in System Settings → Privacy & Security → Speech Recognition.")
                publish { $0.phase = .idle; $0.statusMessage = nil }
                return
            }
        }

        let mic = MicCapture()
        let transcriber = TranscriberSession()
        self.mic = mic
        self.transcriber = transcriber

        tts.amplitudeHandler = { [weak self] level in
            Task { await self?.setMouthLevel(level) }
        }

        do {
            let buffers = try mic.start()
            guard let format = mic.format else { throw NSError(domain: "Voice", code: 1) }
            publish { $0.statusMessage = "Loading speech model (first time can take a while)…" }
            let updates = try await transcriber.start(locale: locale(), micFormat: format)
            publish { $0.statusMessage = nil }

            feedTask = Task {
                for await buffer in buffers {
                    if Task.isCancelled { break }
                    await transcriber.feed(buffer)
                }
            }
            resultTask = Task { [weak self] in
                do {
                    for try await update in updates {
                        await self?.handle(update)
                    }
                } catch {
                    await self?.fail("Speech recognition stopped: \(error.localizedDescription)")
                }
            }

            watchdogTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(200))
                    await self?.checkEndOfTurn()
                    await self?.checkIdleTimeout()
                }
            }
        } catch {
            fail("Could not start voice mode: \(error.localizedDescription)")
            publish { $0.statusMessage = nil }
            await stop()
        }
    }

    public func stop() async {
        turnTask?.cancel(); turnTask = nil
        tts.stop()
        await stopListeningHardware()
        publish { $0.phase = .idle; $0.mouthLevel = 0 }
    }

    /// Tear down mic + transcription only — a running turn (and its
    /// spoken answer) survives. Used by typed-input switching and stop().
    private func stopListeningHardware() async {
        feedTask?.cancel(); feedTask = nil
        resultTask?.cancel(); resultTask = nil
        watchdogTask?.cancel(); watchdogTask = nil
        mic?.stop(); mic = nil
        if let transcriber { await transcriber.stop() }
        transcriber = nil
        utterance = ""; volatileTail = ""
    }

    private func setMouthLevel(_ level: Float) {
        publish { $0.mouthLevel = level }
    }

    private func fail(_ message: String) {
        publish { $0.errorMessage = message }
    }

    // MARK: Turn handling

    private func checkIdleTimeout() async {
        guard snapshot.phase == .listening,
              Date.now.timeIntervalSince(lastInteractionAt) > idleTimeout else { return }
        VoiceLog.log("session: auto-stop after \(Int(idleTimeout))s of silence")
        await stop()
    }

    private func handle(_ update: TranscriberSession.Update) {
        lastResultAt = .now
        lastInteractionAt = .now
        if update.isFinal {
            utterance += (utterance.isEmpty ? "" : " ") + update.text
            volatileTail = ""
        } else {
            volatileTail = update.text
        }
        let combined = (utterance + " " + volatileTail).trimmingCharacters(in: .whitespaces)

        // The recognizer's FINAL for a committed turn arrives AFTER the
        // commit — treat it as an echo, not new input, or every turn
        // barge-ins itself and runs twice.
        if snapshot.phase != .listening, Self.isEcho(combined, of: lastCommittedText) {
            utterance = ""
            volatileTail = ""
            return
        }

        // Speakers: she hears herself — no listening while speaking, and
        // a short deaf window after speaking for the trailing echo.
        if !headphonesActive {
            if snapshot.phase == .speaking || Date.now < echoCooldownUntil {
                utterance = ""
                volatileTail = ""
                return
            }
        } else if snapshot.phase == .speaking,
                  Self.soundsLikeAssistant(combined, reply: snapshot.assistantText) {
            // Headphones: minor bleed can still occur at high volume —
            // keep the similarity guard, allow true barge-in below.
            utterance = ""
            volatileTail = ""
            return
        }
        publish { $0.userPartial = combined }

        // Barge-in: user talks over her thinking — or over her speech,
        // when the output route makes that safe.
        let bargeInAllowed = snapshot.phase == .thinking
            || (snapshot.phase == .speaking && headphonesActive)
        if bargeInAllowed, combined.count >= bargeInThreshold {
            VoiceLog.log("turn: barge-in with \"\(combined)\"")
            bargeIn()
        }
    }

    /// True when the transcribed text is plausibly Aitvaras's own speech
    /// leaking from the speakers: most of its words appear in the reply
    /// she is currently reading out.
    static func soundsLikeAssistant(_ heard: String, reply: String) -> Bool {
        guard !reply.isEmpty else { return false }
        func words(_ s: String) -> [String] {
            s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        }
        let heardWords = words(heard)
        guard heardWords.count >= 2 else { return true }   // too little signal — assume bleed
        let replySet = Set(words(reply))
        let overlap = heardWords.filter { replySet.contains($0) }.count
        return Double(overlap) / Double(heardWords.count) > 0.6
    }

    /// True when `text` is just a re-delivery of the already-committed
    /// utterance (modulo whitespace/punctuation dribble).
    static func isEcho(_ text: String, of committed: String) -> Bool {
        guard !committed.isEmpty else { return false }
        func normalize(_ s: String) -> String {
            s.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        let a = normalize(text)
        let b = normalize(committed)
        return a == b || (b.hasPrefix(a) && !a.isEmpty)
    }

    private func bargeIn() {
        turnTask?.cancel()
        turnTask = nil
        tts.stop()
        let nextPhase: VoicePhase = mic == nil ? .idle : .listening
        publish { $0.phase = nextPhase; $0.assistantText = ""; $0.mouthLevel = 0 }
    }

    private func checkEndOfTurn() {
        guard snapshot.phase == .listening else { return }
        let combined = (utterance + " " + volatileTail).trimmingCharacters(in: .whitespaces)
        guard !combined.isEmpty else { return }
        // Punctuation-only dribble (echo remnants) is not a turn.
        guard combined.contains(where: { $0.isLetter || $0.isNumber }) else {
            utterance = ""; volatileTail = ""
            return
        }
        guard Date.now.timeIntervalSince(lastResultAt) >= endOfTurnSilence else { return }

        utterance = ""
        volatileTail = ""
        lastCommittedText = combined
        publish { $0.userPartial = combined; $0.assistantText = "" }
        VoiceLog.log("turn: committing \"\(combined)\"")
        runTurn(with: combined)
    }

    private func runTurn(with text: String) {
        publish { $0.phase = .thinking }
        let priorHistory = history
        history.append(ChatMessage(role: .user, content: text))

        turnTask = Task { [weak self] in
            guard let self else { return }
            var spoken = ""
            var pendingSentence = ""
            var fullResponse = ""
            let turnStart = Date.now
            var firstDeltaLogged = false

            let replies = self.respond(priorHistory, text)
            for await reply in replies {
                if Task.isCancelled { return }
                switch reply {
                case .delta(let delta):
                    if !firstDeltaLogged {
                        firstDeltaLogged = true
                        VoiceLog.log("turn: first token after \(String(format: "%.1f", Date.now.timeIntervalSince(turnStart)))s")
                    }
                    fullResponse += delta
                    pendingSentence += delta
                    await self.publishAssistant(fullResponse)
                    // Speak complete sentences as they form.
                    while let sentence = Self.extractSentence(from: &pendingSentence) {
                        let clean = Self.sanitizeForSpeech(sentence)
                        guard !clean.isEmpty else { continue }
                        await self.setPhase(.speaking)
                        spoken += clean
                        await self.tts.speak(clean, languageCode: nil)
                        if Task.isCancelled { return }
                    }
                case .done:
                    break
                }
            }
            let rest = Self.sanitizeForSpeech(pendingSentence)
            if !rest.isEmpty, !Task.isCancelled {
                await self.setPhase(.speaking)
                await self.tts.speak(rest, languageCode: nil)
            }
            if !Task.isCancelled {
                VoiceLog.log("turn: done after \(String(format: "%.1f", Date.now.timeIntervalSince(turnStart)))s (\(fullResponse.count) chars)")
                await self.completeTurn(response: fullResponse)
            }
            _ = spoken
        }
    }

    private func publishAssistant(_ text: String) {
        publish { $0.assistantText = text }
    }

    private func setPhase(_ phase: VoicePhase) {
        if phase == .speaking, snapshot.phase != .speaking {
            headphonesActive = AudioRoute.isHeadphones()
            VoiceLog.log("route: \(AudioRoute.describe())")
        }
        if snapshot.phase == .speaking, phase != .speaking, !headphonesActive {
            echoCooldownUntil = Date.now.addingTimeInterval(1.2)
        }
        if snapshot.phase != phase {
            publish { $0.phase = phase }
        }
    }

    private func completeTurn(response: String) {
        history.append(ChatMessage(role: .assistant, content: response))
        if history.count > 24 { history.removeFirst(history.count - 24) }
        lastInteractionAt = .now
        // Typed-only usage has no mic session — return to idle, not to
        // a listening state that isn't real.
        setPhase(mic == nil ? .idle : .listening)
        publish { $0.userPartial = ""; $0.mouthLevel = 0 }
    }

    private var announcementQueue: [String] = []
    private var announcing = false

    /// Proactive speech Aitvaras initiates (break reminder, drift nudge,
    /// urgent message) — spoken aloud with a visible caption, no mic
    /// needed. Queued so rapid nudges don't overlap; skipped (caption
    /// only) if the user is mid-conversation so she never talks over her
    /// own answer.
    public func announce(_ text: String) async {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if turnTask != nil { return }   // user turn in progress
        publish { $0.assistantText = clean }
        announcementQueue.append(clean)
        if announcing { return }

        announcing = true
        while !announcementQueue.isEmpty {
            let next = announcementQueue.removeFirst()
            publish { $0.assistantText = next }
            setPhase(.speaking)
            var buffer = next
            while let sentence = Self.extractSentence(from: &buffer) {
                let spoken = Self.sanitizeForSpeech(sentence)
                if !spoken.isEmpty { await tts.speak(spoken, languageCode: nil) }
            }
            let rest = Self.sanitizeForSpeech(buffer)
            if !rest.isEmpty { await tts.speak(rest, languageCode: nil) }
        }
        announcing = false
        setPhase(mic == nil ? .idle : .listening)
        publish { $0.mouthLevel = 0 }
    }

    /// Typed prompt from the companion window: same brain, same spoken
    /// answer, no microphone. Typing is the explicit "don't listen"
    /// signal — an active mic session is shut down first.
    public func submitTyped(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if snapshot.phase == .thinking || snapshot.phase == .speaking {
            turnTask?.cancel()
            turnTask = nil
            tts.stop()
        }
        if mic != nil {
            await stopListeningHardware()
            VoiceLog.log("session: mic stopped — switched to typed input")
        }
        lastCommittedText = trimmed
        lastInteractionAt = .now
        publish { $0.userPartial = trimmed; $0.assistantText = ""; $0.errorMessage = nil }
        VoiceLog.log("turn: typed \"\(trimmed)\"")
        runTurn(with: trimmed)
    }

    /// Last line of defense before text hits the TTS: models ignore
    /// "no markdown" instructions when summarizing tool output, so strip
    /// formatting mechanically. Content is kept; decoration dies.
    static func sanitizeForSpeech(_ text: String) -> String {
        var s = text
        // Markdown emphasis/code/headings — keep the inner text.
        for token in ["**", "__", "`", "*", "#"] {
            s = s.replacingOccurrences(of: token, with: " ")
        }
        // URLs → the word "link".
        s = s.replacingOccurrences(
            of: #"https?://\S+"#, with: "link", options: .regularExpression)
        // List markers at line starts become sentence flow.
        s = s.replacingOccurrences(
            of: #"(?m)^\s*[-•·]\s+"#, with: " ", options: .regularExpression)
        // Symbols that TTS reads out or garbles.
        s = s.replacingOccurrences(of: "@", with: " at ")
        s = String(s.map { char in
            if char.isLetter || char.isNumber || char.isWhitespace { return char }
            if ".,:;!?'\"()%€$°–—-".contains(char) { return char }
            return " "
        })
        // Collapse the holes we punched.
        s = s.replacingOccurrences(
            of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Pull the first complete sentence (min length guards against
    /// abbreviations like "z.B." producing choppy audio).
    static func extractSentence(from buffer: inout String) -> String? {
        let terminators: Set<Character> = [".", "!", "?", "…", "\n"]
        var index = buffer.startIndex
        while index < buffer.endIndex {
            let char = buffer[index]
            if terminators.contains(char) {
                let candidateEnd = buffer.index(after: index)
                let candidate = String(buffer[..<candidateEnd])
                let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count >= 12 || char == "\n" {
                    buffer = String(buffer[candidateEnd...])
                    return trimmed.isEmpty ? nil : trimmed + " "
                }
            }
            index = buffer.index(after: index)
        }
        return nil
    }
}
