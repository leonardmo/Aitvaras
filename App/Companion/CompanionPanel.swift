import AppKit
import SwiftUI
import AitvarasVoice

/// The floating always-on-top companion window (D4): borderless,
/// draggable, on every Space, toggled with ⌥Space.
/// Borderless panels refuse key status by default — typing in the
/// companion's prompt field needs this override.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class CompanionPanelController {
    private let panel: NSPanel

    init(model: AppModel) {
        panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 292, height: 390),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Window movement is handled only by the portrait's explicit
        // WindowDragGesture. Interactive controls must never drag it.
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true

        let host = NSHostingView(rootView: CompanionView().environment(model))
        panel.contentView = host

        // Bottom-right corner by default.
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: frame.maxX - 312,
                y: frame.minY + 24))
        }
    }

    var isVisible: Bool { panel.isVisible }

    func show() {
        panel.orderFrontRegardless()
    }

    /// Show and take keyboard focus for the typed-prompt field.
    func showForTyping() {
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func toggle() {
        if panel.isVisible { hide() } else { show() }
    }
}

/// What lives inside the panel: Aitvaras herself, a state ring, mic toggle.
struct CompanionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var languageRefresh = false
    @State private var volume = Double(VoiceVolume.gain)
    @State private var typedPrompt = ""
    @FocusState private var promptFocused: Bool
    @State private var hovering = false

    /// Controls appear on hover, while typing, or during an active
    /// conversation — otherwise she stands alone (minimalism request).
    private var controlsVisible: Bool {
        hovering || promptFocused || model.voiceEnabled
    }

    var body: some View {
        VStack(spacing: 0) {
            topControls
                .frame(height: 42)
                .opacity(controlsVisible ? 1 : 0)
                .allowsHitTesting(controlsVisible)

            AvatarView()
                .frame(width: 272, height: 282)
                .background(.clear)
                .glassEffect(.clear.tint(.black.opacity(0.08)),
                             in: RoundedRectangle(cornerRadius: 20))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .strokeBorder(stateColor.opacity(0.42), lineWidth: 0.8)
                )
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .gesture(WindowDragGesture())

            bottomControls
                .frame(height: 44)
                .opacity(controlsVisible ? 1 : 0)
                .allowsHitTesting(controlsVisible)
        }
        .padding(6)
        .glassEffect(
            controlsVisible
                ? .clear.tint(.black.opacity(0.22)).interactive()
                : .identity,
            in: RoundedRectangle(cornerRadius: 27)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 27)
                .strokeBorder(.white.opacity(controlsVisible ? 0.22 : 0), lineWidth: 0.8)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.18), value: controlsVisible)
    }

    /// The upper rail contains every mode/action button. It is part of the
    /// same glass frame as the portrait, rather than a floating toolbar.
    private var topControls: some View {
        HStack(spacing: 7) {
            Button {
                model.toggleVoice()
            } label: {
                Image(systemName: model.voiceEnabled ? "mic.fill" : "mic")
                    .font(.body.weight(.medium))
                    .foregroundStyle(model.voiceEnabled ? .red : .white.opacity(0.92))
                    .frame(width: 30, height: 30)
                    .background(controlSurface)
            }
            .buttonStyle(.plain)
            .help(model.voiceEnabled ? "Stop voice conversation" : "Start voice conversation")

            Button {
                let current = UserDefaults.standard.string(forKey: "voice.locale") ?? "en-US"
                model.setVoiceLanguage(current.hasPrefix("en") ? "de-DE" : "en-US")
                languageRefresh.toggle()
            } label: {
                Text((UserDefaults.standard.string(forKey: "voice.locale") ?? "en-US").hasPrefix("en") ? "EN" : "DE")
                    .font(.caption2.weight(.bold).monospaced())
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(width: 30, height: 30)
                    .background(controlSurface)
            }
            .buttonStyle(.plain)
            .help("Speech recognition language (tap to switch)")
            .id(languageRefresh)

            if model.integrations?.focusCoach?.isEnabled == true {
                Button {
                    model.toggleFocusSession()
                } label: {
                    Image(systemName: model.focusSessionActive ? "moon.fill" : "moon")
                        .foregroundStyle(model.focusSessionActive ? .purple : .white.opacity(0.92))
                        .frame(width: 30, height: 30)
                        .background(controlSurface)
                }
                .buttonStyle(.plain)
                .help(model.focusSessionActive ? "End focus session" : "Start focus session")
            }

            Button {
                model.toggleCapture()
            } label: {
                Image(systemName: model.captureActive ? "record.circle.fill" : "record.circle")
                    .foregroundStyle(model.captureActive ? .red : .white.opacity(0.92))
                    .frame(width: 30, height: 30)
                    .background(controlSurface)
            }
            .buttonStyle(.plain)
            .help(model.captureActive
                ? "Aufnahme beenden (Zusammenfassung wird erstellt)"
                : "Aufnahme starten (Meeting/Vorlesung/Video transkribieren)")

            Spacer(minLength: 8)

            Button {
                openWindow(id: "main")
                NSApp.activate()
            } label: {
                Image(systemName: "rectangle.expand.diagonal")
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(width: 30, height: 30)
                    .background(controlSurface)
            }
            .buttonStyle(.plain)
            .help("Open Aitvaras")
        }
        .padding(.horizontal, 8)
    }

    /// Prompt and volume share a single lower rail. Voice status and
    /// transcript text surface as the prompt placeholder, never as a
    /// detached bubble over the character.
    private var bottomControls: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                TextField(promptPlaceholder, text: $typedPrompt)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.94))
                    .tint(.white)
                    .focused($promptFocused)
                    .onSubmit(sendTypedPrompt)

                Button(action: sendTypedPrompt) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.9))
                }
                .buttonStyle(.plain)
                .disabled(typedPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.18)))
            .onChange(of: model.companionFocusRequest) {
                promptFocused = true
            }

            HStack(spacing: 6) {
                Image(systemName: volume < 0.01 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.86))

                Slider(value: $volume, in: 0...2) { editing in
                    if !editing { VoiceVolume.gain = Float(volume) }
                }
                .controlSize(.mini)
                .frame(width: 48)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(controlSurface)
        }
        .padding(.horizontal, 8)
    }

    private var controlSurface: some View {
        RoundedRectangle(cornerRadius: 9)
            .fill(.black.opacity(0.42))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.18)))
    }

    private var promptPlaceholder: String {
        if let error = model.voiceSnapshot.errorMessage, !error.isEmpty { return error }
        if let status = model.voiceSnapshot.statusMessage, !status.isEmpty { return status }
        if model.voiceEnabled, !model.voiceSnapshot.userPartial.isEmpty {
            return model.voiceSnapshot.userPartial
        }
        if !model.voiceSnapshot.assistantText.isEmpty {
            return model.voiceSnapshot.assistantText
        }
        return "Type to Aitvaras…"
    }

    private func sendTypedPrompt() {
        let prompt = typedPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        model.askCompanion(prompt)
        typedPrompt = ""
    }

    private var stateColor: Color {
        switch model.characterState {
        case .idle: .gray
        case .listening: .teal
        case .thinking: .orange
        case .speaking: .green
        }
    }

}
