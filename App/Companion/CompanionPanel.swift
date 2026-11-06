import AppKit
import SwiftUI
import Observation
import AitvarasCore
import AitvarasVoice

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Retained by the controller so hiding/collapsing cannot lose an unsent draft.
@MainActor
@Observable
final class CompanionOverlayState {
    var isVisible = false
    var draft = ""
    var chatExpanded = false {
        didSet { if oldValue != chatExpanded { layoutChanged() } }
    }
    var subtitlesVisible = false {
        didSet { if oldValue != subtitlesVisible { layoutChanged() } }
    }

    private func layoutChanged() {
        NotificationCenter.default.post(name: .aitvarasCompanionLayoutChanged, object: self)
    }
}

/// One existing floating panel, with optional subtitles and on-demand chat.
@MainActor
final class CompanionPanelController {
    private let panel: NSPanel
    private let model: AppModel
    let overlayState = CompanionOverlayState()
    private var observers: [NSObjectProtocol] = []
    private var layoutAnchor: NSRect?
    private var lastAppliedFrame: NSRect?

    init(model: AppModel) {
        self.model = model
        panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: model.companionPresentation.panelSize),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = NSHostingView(rootView: CompanionView(presentation: overlayState).environment(model))
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - panel.frame.width - 20, y: frame.minY + 24))
        }
        for name in [Notification.Name.aitvarasCompanionPresentationChanged, .aitvarasCompanionLayoutChanged,
                     NSApplication.didChangeScreenParametersNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resizeForPresentation() }
            })
        }
        resizeForPresentation()
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    private func resizeForPresentation() {
        let old = panel.frame
        // Preserve the user's anchor through temporary screen clamping. A real
        // drag establishes a new anchor; a resize performed here does not.
        if lastAppliedFrame == nil || old.origin != lastAppliedFrame?.origin {
            layoutAnchor = old
        }
        let preferred = CompanionOverlayLayout.preferredSize(
            presentation: model.companionPresentation, chatExpanded: overlayState.chatExpanded,
            subtitlesVisible: overlayState.subtitlesVisible)
        let available = (panel.screen ?? NSScreen.main)?.visibleFrame ?? old
        let frame = CompanionOverlayLayout.frame(preferredSize: preferred, anchoredTo: layoutAnchor ?? old, within: available)
        panel.setFrame(frame, display: true, animate: false)
        lastAppliedFrame = frame
    }

    var isVisible: Bool { panel.isVisible }
    var diagnosticContentView: NSView? { panel.contentView }
    var diagnosticFrame: NSRect { panel.frame }

    func show() {
        overlayState.isVisible = true
        resizeForPresentation()
        panel.orderFrontRegardless()
    }

    func showForTyping() {
        overlayState.chatExpanded = true
        show()
        panel.makeKey()
    }

    func hide() {
        panel.orderOut(nil)
        // Remove visual consumers, not capture/inference or conversation state.
        overlayState.isVisible = false
    }

    func toggle() { if panel.isVisible { hide() } else { show() } }
}

extension CompanionPresentation {
    var panelSize: NSSize {
        CompanionOverlayLayout.preferredSize(presentation: self, chatExpanded: false, subtitlesVisible: false)
    }
}

extension Notification.Name {
    static let aitvarasCompanionPresentationChanged = Notification.Name("aitvaras.companionPresentationChanged")
    static let aitvarasCompanionLayoutChanged = Notification.Name("aitvaras.companionLayoutChanged")
}

struct CompanionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Bindable var presentation: CompanionOverlayState
    @State private var languageRefresh = false
    @State private var volume = Double(VoiceVolume.gain)
    @FocusState private var promptFocused: Bool

    var body: some View {
        Group {
            if presentation.isVisible { panelContents } else { Color.clear }
        }
        .onChange(of: model.companionFocusRequest) {
            presentation.chatExpanded = true
            promptFocused = true
        }
    }

    private var panelContents: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                // The companion wears the same mark as the menu bar.
                Image("DragonMenu")
                    .renderingMode(.template)
                    .resizable().scaledToFit()
                    .frame(width: 14, height: 14)
                    .foregroundStyle(.secondary)
                Text("Aitvaras").font(.caption.weight(.semibold))
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
            .help("Drag here to move the companion")

            CompactActivityStatusView()

            // Neither minimal mode nor expanded chat mounts a 3D renderer.
            if model.companionPresentation.usesAvatar && !presentation.chatExpanded {
                AvatarView().frame(height: 218)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .gesture(WindowDragGesture())
            }
            if presentation.subtitlesVisible { CompanionSubtitleView() }
            controls
            if presentation.chatExpanded { chat }
        }
        .padding(12)
        .neutralGlass(cornerRadius: 22)
        .padding(3)
        .contextMenu {
            Button(model.companionPresentation.usesAvatar ? "Use minimal overlay" : "Show avatar") {
                model.companionPresentation = model.companionPresentation.usesAvatar ? .minimal : .avatar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button {
                presentation.chatExpanded.toggle()
                promptFocused = presentation.chatExpanded
            } label: {
                Label(presentation.chatExpanded ? "Collapse chat" : "Chat", systemImage: presentation.chatExpanded ? "chevron.down" : "bubble.left.and.bubble.right")
                    .font(.caption.weight(.medium)).padding(.horizontal, 9).frame(height: 30)
                    .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            }
            .help(presentation.chatExpanded ? "Collapse chat; keep conversation and draft" : "Open chat inside this overlay")
            iconButton(presentation.subtitlesVisible ? "captions.bubble.fill" : "captions.bubble",
                       label: presentation.subtitlesVisible ? "Hide subtitles" : "Show subtitles") {
                presentation.subtitlesVisible.toggle()
            }
            .accessibilityValue(presentation.subtitlesVisible ? "Shown" : "Hidden")
            iconButton(model.voiceEnabled ? "mic.fill" : "mic",
                       label: model.voiceEnabled ? "Stop voice conversation" : "Start voice conversation") {
                model.toggleVoice()
            }
            .foregroundStyle(model.voiceEnabled ? ActivityGlassPalette.recording : Color.primary)
            .disabled(model.selectedWorkspaceProjectID != nil && !model.voiceEnabled)
            .help(model.selectedWorkspaceProjectID == nil ? "Local voice conversation" : "Voice is available in Unassigned")
            .accessibilityIdentifier("chat.companion.voice")
            Spacer(minLength: 0)
            moreControls
            iconButton("rectangle.expand.diagonal", label: "Open Aitvaras") {
                openWindow(id: "main")
                NSApp.activate()
            }
        }
        .buttonStyle(.plain)
    }

    private var moreControls: some View {
        Menu {
            Button("Switch listening language (\(listeningLanguage))") {
                model.setVoiceLanguage(listeningLanguage == "EN" ? "de-DE" : "en-US")
                languageRefresh.toggle()
            }
            Button(model.captureActive ? "Stop recording" : "Start recording") { model.toggleCapture() }
            if model.integrations?.focusCoach?.isEnabled == true {
                Button(model.focusSessionActive ? "End focus session" : "Start focus session") { model.toggleFocusSession() }
            }
            Divider()
            Button(model.companionPresentation.usesAvatar ? "Use minimal overlay" : "Show avatar") {
                model.companionPresentation = model.companionPresentation.usesAvatar ? .minimal : .avatar
            }
            Divider()
            Text("Voice volume")
            Slider(value: $volume, in: 0...2) { editing in
                if !editing { VoiceVolume.gain = Float(volume) }
            }.frame(width: 140)
        } label: {
            Image(systemName: "ellipsis").frame(width: 30, height: 30)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .id(languageRefresh).help("More companion controls")
        .accessibilityLabel("More companion controls")
    }

    @ViewBuilder private var chat: some View {
        if let id = model.selectedWorkspaceChatID, let chat = model.chatModel {
            AgentChatView(chat: chat, chatID: id, canSend: model.selectedWorkspaceChat?.archivedAt == nil,
                          compact: true)
                .accessibilityIdentifier("chat.companion")
        } else {
            localChat
        }
    }

    private var localChat: some View {
        VStack(spacing: 10) {
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if model.messages.isEmpty {
                            Text("Message Aitvaras here. This is the same saved conversation as Chat in the main app.")
                                .font(.callout).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if model.earlierChatMessagesAreHidden {
                            Text("Earlier messages remain saved in the main app.").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(model.messages) { message in
                            MessageBubble(message: message).id(message.id)
                        }
                    }.padding(.vertical, 6)
                }
                .onAppear { if let id = model.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
                .onChange(of: model.messages.last?.text) {
                    if let id = model.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }.frame(maxHeight: .infinity)
            HStack(alignment: .bottom, spacing: 9) {
                TextField("Message Aitvaras…", text: $presentation.draft, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(2...5).focused($promptFocused)
                    .onSubmit(send).accessibilityIdentifier("chat.companion.input").padding(10)
                    .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(model.isResponding || model.microphoneInUseByVoice || model.localAgentReplyActive || model.selectedUnassignedVoiceHistory || model.selectedChatConversationID == nil || presentation.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help(model.isResponding ? "A reply is in progress; your draft is kept" : "Send message")
                .accessibilityLabel("Send message").accessibilityIdentifier("chat.companion.send")
            }
            if model.isResponding {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Reply in progress · collapsing chat keeps it running").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Stop", systemImage: "stop.fill") { model.cancelTurn() }
                        .labelStyle(.iconOnly).accessibilityIdentifier("chat.companion.stop")
                }
            }
        }.frame(maxHeight: .infinity)
    }

    private var listeningLanguage: String {
        (AitvarasPreferences.current.string(forKey: "voice.locale") ?? "en-US").hasPrefix("en") ? "EN" : "DE"
    }

    private func send() {
        if model.send(presentation.draft) { presentation.draft = "" }
        promptFocused = true
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 30, height: 30) }
            .help(label).accessibilityLabel(label)
    }
}

/// A view of current recognizer state, never a second transcription pipeline.
/// It is absent when subtitles or the panel are hidden.
private struct CompanionSubtitleView: View {
    @Environment(AppModel.self) private var model
    @State private var details = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(model.capture?.isActive == true ? "Live subtitles" : "Latest subtitles").font(.caption.weight(.semibold))
                Spacer()
                if let source = model.capture?.liveCaptionSource, !source.isEmpty {
                    Text(source).font(.caption2).foregroundStyle(.secondary)
                }
                Button { details.toggle() } label: {
                    Image(systemName: model.capture?.durabilityWarning == nil ? "info.circle" : "exclamationmark.triangle")
                }
                .buttonStyle(.plain).help("Show capture scope, inputs and save health")
                .accessibilityLabel("Capture scope, inputs and save health")
                .popover(isPresented: $details) { captureDetails }
            }
            Text(captionText).font(.callout)
                .foregroundStyle(hasCaption ? Color.primary : Color.secondary)
                .lineLimit(2).truncationMode(.head)
                .frame(maxWidth: .infinity, minHeight: 38, maxHeight: 38, alignment: .topLeading)
                .accessibilityLabel(captionText)
            Text(!hasCaption ? "Subtitle visibility does not change recording" : model.capture?.liveCaptionIsFinal == true ? "Recognized phrase · saving uses transcript checkpoints" : "Provisional recognition · words may change")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(10)
        .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
        .frame(height: 100)
    }

    private var hasCaption: Bool { !(model.capture?.liveCaption ?? "").isEmpty }
    private var captionText: String {
        if let caption = model.capture?.liveCaption, !caption.isEmpty { return caption }
        return model.capture?.isActive == true ? "Waiting for recognized speech…" : "No live recording. Start capture from More controls."
    }

    private var captureDetails: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Capture health").font(.headline)
                if let capture = model.capture {
                    Text(capture.scopeLabel.isEmpty ? "No capture inputs selected" : capture.scopeLabel).font(.callout)
                    if capture.isActive {
                        level("Microphone", value: capture.microphoneLevel)
                        level("System audio", value: capture.systemAudioLevel)
                    }
                    if let warning = capture.durabilityWarning {
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(ActivityGlassPalette.attention)
                    } else {
                        Text("Live words may change. Durable transcript checkpoints are handled by the capture session.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if hasCaption {
                        Text(capture.liveCaption).font(.callout).lineLimit(8).textSelection(.enabled)
                    }
                    if !capture.lastScreenText.isEmpty {
                        Text("Last screen text").font(.caption.weight(.semibold))
                        Text(capture.lastScreenText).font(.caption).lineLimit(6).textSelection(.enabled)
                    }
                } else {
                    Text("No capture session available.").font(.callout)
                }
                Text("Source labels describe audio inputs, not speaker identities. Screen text is kept out of subtitles.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Hiding subtitles or the companion does not stop recording.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(16)
        }.frame(width: 330, height: 360)
    }

    private func level(_ title: String, value: Float) -> some View {
        HStack {
            Text(title).font(.caption).frame(width: 90, alignment: .leading)
            ProgressView(value: Double(min(max(value, 0), 1))).tint(ActivityGlassPalette.ember)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) input level")
        .accessibilityValue("\(Int(min(max(value, 0), 1) * 100)) percent")
    }
}
