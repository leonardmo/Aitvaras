import SwiftUI
import AVFoundation
import EventKit
import AppKit
import AitvarasCore
import AitvarasVoice
import AitvarasEngines
import AitvarasConnectors
import AitvarasAgent

/// Focused setup pages. Optional permissions and technical diagnostics never
/// become a mandatory, all-or-nothing first-run checklist.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var speechGranted = TranscriberSession.authorizationStatus() == .authorized
    @State private var calendarGranted = EKEventStore.authorizationStatus(for: .event) == .fullAccess
    @State private var remindersGranted = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    @State private var mailStatus = "untested"
    @State private var avatarInstalled = AvatarLocator.avatarExists()
    @State private var voiceTestText = "Hello! I'm Aitvaras. It's good to see you."
    @State private var neuralLog = ""
    @State private var voiceTestRunning = false
    @State private var selectedPage: SetupPage
    @State private var selectedAvatar = AvatarLocator.style
    @State private var localModelCount = MLXEngine.installedModels().count
    @State private var voiceVolume = Double(VoiceVolume.gain)

    var openProviders: (() -> Void)?
    @State private var showingProviders = false

    private let eventStore = EKEventStore()
    private static let dragonPreview = Bundle.main.url(forResource: "AitvarasDragonPreview", withExtension: "png")
        .flatMap { NSImage(contentsOf: $0) }

    init(initialPage: SetupPage = .overview, openProviders: (() -> Void)? = nil) {
        self.openProviders = openProviders
        _selectedPage = State(initialValue: initialPage)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Setup").font(.largeTitle.weight(.semibold))
                    Spacer()
                    Label("Changes save automatically", systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("Section", selection: $selectedPage) {
                    ForEach(SetupPage.allCases) { page in Text(page.title).tag(page) }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 300, alignment: .leading)
                .accessibilityLabel("Setup section")
            }
            .padding(24)
            Divider()
            if selectedPage == .overview {
                overview
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 5) {
                        Label(selectedPage.title, systemImage: selectedPage.icon)
                            .font(.title2.weight(.semibold))
                        Text(selectedPage.detail).font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 4)
                    settingsForm
                        .id(selectedPage)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Setup")
        .sheet(isPresented: $showingProviders) {
            if let chat = model.chatModel { AgentProviderSettingsView(chat: chat).frame(width: 560, height: 320) }
        }
        .onChange(of: selectedAvatar) { AvatarLocator.style = selectedAvatar }
        .onChange(of: selectedPage) {
            if selectedPage == .overview {
                localModelCount = MLXEngine.installedModels().count
                refreshPermissions()
            }
        }
        .onChange(of: voiceVolume) { VoiceVolume.gain = Float(voiceVolume) }
        .onChange(of: model.modelDownloads.completionRevision) {
            localModelCount = MLXEngine.installedModels().count
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
            selectedAvatar = AvatarLocator.style
            voiceVolume = Double(VoiceVolume.gain)
        }
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(SetupPage.overview.title).font(.title2.weight(.semibold))
                    Text(SetupPage.overview.detail).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Image(systemName: intelligenceAvailable ? "checkmark.circle.fill" : "arrow.down.circle")
                        .font(.title2).foregroundStyle(intelligenceAvailable ? .green : Color.accentColor)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.modelDownloads.activeModelID != nil ? "Downloading a local model"
                             : intelligenceAvailable ? "Local intelligence available" : "Start with local intelligence")
                            .font(.headline)
                        Text(intelligenceAvailable ? "Choose the model for chat, voice and background work."
                             : "Download a model to run AI on this Mac. No cloud account is needed.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(model.modelDownloads.activeModelID != nil ? "View download"
                           : intelligenceAvailable ? "Manage models" : "Choose a model") { selectedPage = .models }
                        .buttonStyle(.borderedProminent)
                }
                .padding(16)
                .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))

                Button {
                    if let openProviders { openProviders() } else { showingProviders = true }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "cpu").foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("AI providers").font(.headline)
                            Text("Local, Claude and Codex").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                    }.padding(16).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain).accessibilityIdentifier("settings.providers")
                Text("Explore your settings").font(.headline)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    overviewCard(.capture, status: "Apple on-device · language, assets & summaries")
                    overviewCard(.voice, status: model.neuralVoiceInstaller.isInstalling ? "Voice installation in progress"
                                 : micGranted && speechGranted ? "Voice access ready" : "Optional · listening & speaking")
                    overviewCard(.avatar, status: !model.companionPresentation.usesAvatar ? "Minimal overlay · no 3D rendering"
                                 : selectedAvatar == .creature ? "Fire-drake selected" : "Human avatar selected")
                    overviewCard(.cloud, status: "Choose what may leave this Mac")
                    overviewCard(.access, status: "Optional · grant only what you need")
                    overviewCard(.memory, status: NightlyScheduleSettings.load().mode == .off ? "Automatic updates off" : "Automatic updates configured")
                    overviewCard(.usage, status: "Local and cloud activity")
                }
                Label("Connected services are managed separately in Connections.", systemImage: "app.connected.to.app.below.fill")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 960, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var intelligenceAvailable: Bool {
        localModelCount > 0 || !["none", "…", ""].contains(model.engineName)
    }

    private func overviewCard(_ page: SetupPage, status: String) -> some View {
        Button { selectedPage = page } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: page.icon)
                    .font(.title3).foregroundStyle(Color.accentColor).frame(width: 26)
                VStack(alignment: .leading, spacing: 5) {
                    Text(page.title).font(.headline).foregroundStyle(.primary)
                    Text(status).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 2)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.07)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(page.title). \(status)")
    }

    private var settingsForm: some View {
        Form {
            switch selectedPage {
            case .overview: EmptyView()
            case .models:
                Section("Current engine") {
                    LabeledContent("Engine", value: model.engineName == "none" ? "Not connected"
                                   : model.engineName == "…" ? "Checking availability…" : model.engineName)
                }
                ModelsSection(pane: .localModels)
            case .cloud: ModelsSection(pane: .cloudAgents)
            case .memory: ModelsSection(pane: .memory)
            case .usage: ModelsSection(pane: .usage)
            case .voice: voiceSettings
            case .capture: CaptureSettingsView()
            case .avatar: avatarSettings
            case .access: accessSettings
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var voicePermissions: some View {
        row(done: micGranted, title: "Microphone", detail: "Listen during a voice conversation") {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in micGranted = granted }
            }
        }
        row(done: speechGranted, title: "Speech recognition", detail: "Transcribe your speech on this Mac") {
            Task { speechGranted = await TranscriberSession.requestAuthorization() }
        }
    }

    @ViewBuilder private var voiceSettings: some View {
        Section("Listening") {
            voicePermissions
            Text("The EN/DE button on the companion chooses the language it listens for.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Manage English / German speech assets") { selectedPage = .capture }
            Text("Voice and capture share Apple's on-device speech assets, but keep separate language selections.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Speaking") {
            row(done: model.neuralVoiceInstaller.installed, title: "Local neural voice",
                detail: model.neuralVoiceInstaller.installed
                    ? "Installed · Aitvaras speaks English with Kokoro."
                    : "Optional · about 6 GB for the voice environment and bundled models. Runs locally.")
            if !model.neuralVoiceInstaller.installed {
                if model.neuralVoiceInstaller.isInstalling {
                    Button(model.neuralVoiceInstaller.isCancelling ? "Pausing…" : "Pause installation") {
                        model.neuralVoiceInstaller.cancelActive()
                    }.disabled(model.neuralVoiceInstaller.isCancelling)
                } else {
                    Button(model.neuralVoiceInstaller.status.isEmpty ? "Install neural voice" : "Retry installation") {
                        neuralLog = ""
                        model.neuralVoiceInstaller.start()
                    }
                }
            }
            if !model.neuralVoiceInstaller.status.isEmpty {
                Text(model.neuralVoiceInstaller.status).font(.caption).foregroundStyle(.secondary)
            }
            LabeledContent("Volume") { Slider(value: $voiceVolume, in: 0...2).frame(maxWidth: 260) }
            Text("Spoken replies stay in English, independently of the language you speak. Apple voices are the fallback when the neural voice is unavailable.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Try the voice") {
            TextField("Test sentence", text: $voiceTestText)
            Button(voiceTestRunning ? "Testing…" : "Test neural voice") { testNeuralVoice() }
                .disabled(!model.neuralVoiceInstaller.installed || model.neuralTTS == nil || voiceTestRunning || voiceTestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if !neuralLog.isEmpty { Text(neuralLog).font(.caption).foregroundStyle(.secondary) }
            DisclosureGroup("Apple fallback & diagnostics") {
                LabeledContent("English voice", value: AppleTTS.bestVoice(for: "en")?.name ?? "Not available")
                Button("Test Apple fallback") {
                    let text = voiceTestText
                    Task.detached { await AppleTTS().speak(text) }
                }
            }
        }
    }

    @ViewBuilder private var avatarSettings: some View {
        Section("Floating companion") {
            Picker("Display", selection: Binding(
                get: { model.companionPresentation },
                set: { model.companionPresentation = $0 })) {
                Text("Avatar").tag(CompanionPresentation.avatar)
                Text("Minimal overlay").tag(CompanionPresentation.minimal)
            }.pickerStyle(.segmented)
            Text(model.companionPresentation.usesAvatar
                 ? "Show your character with controls on hover."
                 : "A compact, draggable overlay with voice, typing and volume controls. The avatar is not loaded or rendered.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Option–Space shows or hides either mode. Switching modes keeps your selected character and voice session.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if model.companionPresentation.usesAvatar {
            Section("Appearance") { avatarAppearance }
        }
    }

    @ViewBuilder private var avatarAppearance: some View {
        Picker("Character", selection: $selectedAvatar) {
            Text("Fire-drake companion").tag(AvatarStyle.creature)
            Text("Human avatar").tag(AvatarStyle.human)
        }.pickerStyle(.segmented)
        HStack(spacing: 18) {
            if selectedAvatar == .creature, let preview = Self.dragonPreview {
                Image(nsImage: preview).resizable().scaledToFit().frame(width: 100, height: 120)
            } else {
                Image(systemName: "person.crop.square").font(.system(size: 66)).foregroundStyle(.secondary)
                    .frame(width: 100, height: 120)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(selectedAvatar == .creature ? "Aitvaras, the fire-drake" : "A familiar human presence").font(.headline)
                Text(selectedAvatar == .creature
                     ? "A textured dragon with blinking eyes, expressive gaze and speech-driven mouth movement."
                     : "A stylized human avatar with blinking, lip-sync and facial expressions.")
                    .foregroundStyle(.secondary)
                Label("Pauses rendering when hidden", systemImage: "leaf")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
        if selectedAvatar == .human {
            Button("Import your own GLB…") { importAvatar() }
            if avatarInstalled { Button("Restore the default human avatar") { removeCustomAvatar() } }
            Text("Custom models need Ready-Player-Me-style ARKit blendshapes.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var accessSettings: some View {
        Section("Voice access") { voicePermissions }
        Section("Personal apps · optional") {
            row(done: calendarGranted, title: "Calendar", detail: "Read events and create Aitvaras's own events") {
                eventStore.requestFullAccessToEvents { granted, _ in Task { @MainActor in calendarGranted = granted } }
            }
            row(done: remindersGranted, title: "Reminders", detail: "Read reminders and create tasks") {
                eventStore.requestFullAccessToReminders { granted, _ in Task { @MainActor in remindersGranted = granted } }
            }
            HStack {
                Image(systemName: mailStatus == "ok" ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(mailStatus == "ok" ? .green : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Apple Mail")
                    Text(mailStatus == "untested" ? "Test access with Mail open. macOS may ask for permission." : mailStatus)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Test access") { testMail() }
            }
            Text("Mail access is read-only. This test does not send mail.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func refreshPermissions() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        speechGranted = TranscriberSession.authorizationStatus() == .authorized
        calendarGranted = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        remindersGranted = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    }

    @ViewBuilder
    private func row(
        done: Bool, title: String, detail: String,
        action: (() -> Void)? = nil
    ) -> some View {
        HStack {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? .green : .secondary)
            VStack(alignment: .leading) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !done, let action {
                Button("Grant") { action() }
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

    private func testNeuralVoice() {
        guard let neural = model.neuralTTS else { return }
        voiceTestRunning = true
        neuralLog = "Starting the local voice engine. A cold start may take up to a minute…"
        let text = voiceTestText
        Task {
            defer { voiceTestRunning = false }
            guard await neural.ensureServer() else {
                neuralLog = "The neural voice could not start. You can test the Apple fallback below."
                return
            }
            await neural.speak(text, languageCode: "en")
            neuralLog = "Voice test finished."
        }
    }

    private func removeCustomAvatar() {
        do {
            try FileManager.default.removeItem(at: AvatarLocator.avatarURL)
            avatarInstalled = false
            NotificationCenter.default.post(name: .aitvarasAvatarChanged, object: nil)
        } catch {
            model.presentError(title: "Avatar could not be removed", error: error)
        }
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
            avatarInstalled = AvatarLocator.avatarExists()
            model.presentError(title: "Avatar could not be imported", error: error)
        }
    }
}

enum AvatarStyle: String {
    case human       // Ready Player Me avatar
    case creature    // authored dragon companion
}

enum AvatarLocator {
    static var style: AvatarStyle {
        get {
            if let override = ProcessInfo.processInfo.environment["AITVARAS_AVATAR_STYLE"],
               let style = AvatarStyle(rawValue: override) { return style }
            return AvatarStyle(rawValue: AitvarasPreferences.current.string(forKey: "avatar.style") ?? "creature") ?? .creature
        }
        set {
            AitvarasPreferences.current.set(newValue.rawValue, forKey: "avatar.style")
            NotificationCenter.default.post(name: .aitvarasAvatarChanged, object: nil)
        }
    }

    /// User-supplied replacement (optional).
    static var avatarURL: URL {
        AitvarasPaths.stateDirectory
            .appendingPathComponent("Avatar/aitvaras.glb")
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
        let staged = dir.appendingPathComponent(".avatar-\(UUID().uuidString).glb")
        defer { try? FileManager.default.removeItem(at: staged) }
        try FileManager.default.copyItem(at: source, to: staged)
        let size = try staged.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if FileManager.default.fileExists(atPath: avatarURL.path) {
            _ = try FileManager.default.replaceItemAt(avatarURL, withItemAt: staged)
        } else {
            try FileManager.default.moveItem(at: staged, to: avatarURL)
        }
    }
}

extension Notification.Name {
    static let aitvarasAvatarChanged = Notification.Name("aitvarasAvatarChanged")
}
