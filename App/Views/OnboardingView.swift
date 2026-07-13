import SwiftUI
import AVFoundation
import EventKit
import AppKit
import AitvarasVoice
import AitvarasEngines

/// First-run checklist: permissions, models, voice, avatar. Each row is
/// independently retryable — nothing blocks anything else.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var speechGranted = TranscriberSession.authorizationStatus() == .authorized
    @State private var calendarGranted = EKEventStore.authorizationStatus(for: .event) == .fullAccess
    @State private var remindersGranted = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    @State private var mailStatus = "untested"
    @State private var speechModelStatus = ""
    @State private var avatarInstalled = AvatarLocator.avatarExists()
    @State private var voiceTestText = "Hallo! Ich bin Aitvaras. Schön, dass du da bist."
    @State private var neuralInstalled = NeuralTTS.isInstalled()
    @State private var installingNeural = false
    @State private var neuralLog = ""

    private let eventStore = EKEventStore()

    var body: some View {
        Form {
            Section("Brain") {
                row(done: mlxReady,
                    title: "Local models (MLX)",
                    detail: mlxReady ? "Ready" : "Missing — check ~/Library/Application Support/Aitvaras/Models") {}
                LabeledContent("Active engine", value: model.engineName)
            }

            ModelsSection()

            Section("Permissions") {
                row(done: micGranted, title: "Microphone", detail: "For voice conversations") {
                    AVCaptureDevice.requestAccess(for: .audio) { granted in
                        Task { @MainActor in micGranted = granted }
                    }
                }
                row(done: speechGranted, title: "Speech recognition", detail: "On-device transcription") {
                    Task {
                        speechGranted = await TranscriberSession.requestAuthorization()
                    }
                }
                row(done: calendarGranted, title: "Calendar", detail: "Read events, create her own") {
                    eventStore.requestFullAccessToEvents { granted, _ in
                        Task { @MainActor in calendarGranted = granted }
                    }
                }
                row(done: remindersGranted, title: "Reminders", detail: "Read + create todos") {
                    eventStore.requestFullAccessToReminders { granted, _ in
                        Task { @MainActor in remindersGranted = granted }
                    }
                }
                HStack {
                    Image(systemName: mailStatus == "ok" ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(mailStatus == "ok" ? .green : .secondary)
                    VStack(alignment: .leading) {
                        Text("Apple Mail automation")
                        Text(mailStatus == "untested"
                             ? "Grant when macOS asks (Mail must be running)"
                             : mailStatus)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Test") { testMail() }
                }
            }

            Section("Voice") {
                HStack {
                    Button("Download German model") { ensureSpeech("de-DE") }
                    Button("Download English model") { ensureSpeech("en-US") }
                    if !speechModelStatus.isEmpty {
                        Text(speechModelStatus).font(.caption).foregroundStyle(.secondary)
                    }
                }
                LabeledContent("German voice", value: AppleTTS.bestVoice(for: "de")?.name ?? "none")
                LabeledContent("English voice", value: AppleTTS.bestVoice(for: "en")?.name ?? "none")
                HStack {
                    TextField("Test sentence", text: $voiceTestText)
                    Button("Speak") {
                        let text = voiceTestText
                        Task.detached { await AppleTTS().speak(text) }
                    }
                }
                Text("Apple voices are only the fallback. The neural voice below is the real one.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Section("Neural voice (Chatterbox — recommended)") {
                row(done: neuralInstalled,
                    title: "Chatterbox Multilingual",
                    detail: neuralInstalled
                        ? "Installed — Aitvaras speaks with her neural voice (German + English)"
                        : "~6 GB one-time install (Python env + model). Runs fully local on the GPU.") {}
                HStack {
                    if !neuralInstalled {
                        Button(installingNeural ? "Installing…" : "Install neural voice") { installNeuralVoice() }
                            .disabled(installingNeural)
                    }
                    Button("Test neural voice") { testNeuralVoice() }
                        .disabled(!neuralInstalled)
                }
                if !neuralLog.isEmpty {
                    Text(neuralLog)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                LabeledContent("Voice volume") {
                    Slider(value: Binding(
                        get: { Double(VoiceVolume.gain) },
                        set: { VoiceVolume.gain = Float($0) }), in: 0...2)
                        .frame(width: 220)
                }
                Text("Aitvaras always speaks English with her Kokoro voice, regardless of the language you use. The EN/DE button on the companion switches which language she LISTENS for.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Section("Avatar") {
                Picker("Style", selection: Binding(
                    get: { AvatarLocator.style },
                    set: { AvatarLocator.style = $0 })) {
                    Text("Human avatar").tag(AvatarStyle.human)
                    Text("Companion creature").tag(AvatarStyle.creature)
                }
                .pickerStyle(.segmented)
                Text(AvatarLocator.style == .creature
                     ? "A small floating droid-creature: glowing eyes that blink and change with her mood, a light-mouth that lip-syncs. Non-human, fully expressive."
                     : "A stylized human avatar (blink, lip-sync, expressions via ARKit blendshapes).")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                if AvatarLocator.style == .human {
                    HStack {
                        Button("Replace with own .glb…") { importAvatar() }
                        if avatarInstalled {
                            Button("Back to Aitvaras's default") { removeCustomAvatar() }
                        }
                    }
                    Text("Replacements need a Ready-Player-Me-style GLB with ARKit blendshapes.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Setup")
    }

    private var mlxReady: Bool {
        FileManager.default.fileExists(
            atPath: MLXEngine.modelsDirectory()
                .appendingPathComponent("Qwen3-30B-A3B-4bit/config.json").path)
    }

    @ViewBuilder
    private func row(done: Bool, title: String, detail: String, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? .green : .secondary)
            VStack(alignment: .leading) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !done {
                Button("Grant") { action() }
            }
        }
    }

    private func ensureSpeech(_ identifier: String) {
        speechModelStatus = "Downloading…"
        Task {
            do {
                let ok = try await TranscriberSession.ensureModel(locale: Locale(identifier: identifier))
                speechModelStatus = ok ? "\(identifier) ready" : "\(identifier) not supported"
            } catch {
                speechModelStatus = "Failed: \(error.localizedDescription)"
            }
        }
    }

    private func testMail() {
        Task {
            guard let hub = model.hub,
                  let mail = await hub.connectors["mail"] else {
                mailStatus = "Mail connector missing"
                return
            }
            do {
                _ = try await mail.execute(toolName: "recent_messages", argumentsJSON: #"{"count": 1}"#)
                mailStatus = "ok"
            } catch {
                mailStatus = "Failed: \(error.localizedDescription)"
            }
        }
    }

    private func installNeuralVoice() {
        installingNeural = true
        neuralLog = "Starting install (this downloads several GB)…"
        guard let script = Bundle.main.url(forResource: "setup-neural-voice", withExtension: "sh") else {
            neuralLog = "setup-neural-voice.sh missing from the app bundle — rebuild the app."
            installingNeural = false
            return
        }
        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [script.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                for try await line in pipe.fileHandleForReading.bytes.lines {
                    await MainActor.run { neuralLog = line }
                }
                process.waitUntilExit()
                let ok = process.terminationStatus == 0
                await MainActor.run {
                    installingNeural = false
                    neuralInstalled = NeuralTTS.isInstalled()
                    neuralLog = ok ? "Installed ✓" : "Install failed — see Console or run scripts/setup-neural-voice.sh manually"
                }
            } catch {
                await MainActor.run {
                    installingNeural = false
                    neuralLog = "Could not run installer: \(error.localizedDescription)"
                }
            }
        }
    }

    private func testNeuralVoice() {
        guard let neural = model.neuralTTS else { return }
        neuralLog = "Loading model (first time takes up to a minute)…"
        Task {
            _ = await neural.ensureServer()
            await neural.speak("Hallo! Ich bin Aitvaras, und das ist meine richtige Stimme.", languageCode: "de")
            await neural.speak("And this is how I sound in English.", languageCode: "en")
            neuralLog = "Done."
        }
    }

    private func removeCustomAvatar() {
        try? FileManager.default.removeItem(at: AvatarLocator.avatarURL)
        avatarInstalled = false
        NotificationCenter.default.post(name: .aitvarasAvatarChanged, object: nil)
    }

    private func importAvatar() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "glb")!]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        do {
            try AvatarLocator.install(from: source)
            avatarInstalled = true
            NotificationCenter.default.post(name: .aitvarasAvatarChanged, object: nil)
        } catch {
            avatarInstalled = false
        }
    }
}

enum AvatarStyle: String {
    case human       // Ready Player Me avatar
    case creature    // procedural futuristic companion
}

enum AvatarLocator {
    static var style: AvatarStyle {
        get { AvatarStyle(rawValue: UserDefaults.standard.string(forKey: "avatar.style") ?? "human") ?? .human }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "avatar.style")
            NotificationCenter.default.post(name: .aitvarasAvatarChanged, object: nil)
        }
    }

    /// User-supplied replacement (optional).
    static var avatarURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aitvaras/Avatar/aitvaras.glb")
    }

    /// Aitvaras's own bundled avatar (D4) — always present.
    static var bundledAvatarURL: URL? {
        Bundle.main.url(forResource: "AitvarasAvatar", withExtension: "glb")
    }

    /// What the companion actually renders: custom override, else bundled.
    static var effectiveAvatarURL: URL? {
        if FileManager.default.fileExists(atPath: avatarURL.path) { return avatarURL }
        return bundledAvatarURL
    }

    static func avatarExists() -> Bool {
        FileManager.default.fileExists(atPath: avatarURL.path)
    }

    static func install(from source: URL) throws {
        let dir = avatarURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: avatarURL.path) {
            try FileManager.default.removeItem(at: avatarURL)
        }
        try FileManager.default.copyItem(at: source, to: avatarURL)
    }
}

extension Notification.Name {
    static let aitvarasAvatarChanged = Notification.Name("aitvarasAvatarChanged")
}
