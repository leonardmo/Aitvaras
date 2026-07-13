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
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 380),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true

        let host = NSHostingView(rootView: CompanionView().environment(model))
        panel.contentView = host

        // Bottom-right corner by default.
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: frame.maxX - 260,
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
        VStack(spacing: 8) {
            if model.focusSessionActive {
                Label("Focus session", systemImage: "moon.fill")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.indigo)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(.indigo.opacity(0.15)))
                    .overlay(Capsule().strokeBorder(.indigo.opacity(0.4)))
            }
            if model.captureActive {
                Label(model.capture?.scopeLabel ?? "Aufnahme", systemImage: "record.circle.fill")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(.red.opacity(0.15)))
                    .overlay(Capsule().strokeBorder(.red.opacity(0.4)))
                    .help("Capture läuft — Klick auf den Aufnahmeknopf beendet sie")
            }

            ZStack(alignment: .bottom) {
                AvatarView()
                    .frame(width: 220, height: 260)
                    .background(
                        RoundedRectangle(cornerRadius: 24)
                            .fill(.black.opacity(0.35))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 24)
                            .strokeBorder(stateColor.opacity(0.8), lineWidth: 1.5)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 24))

                if !model.voiceSnapshot.userPartial.isEmpty && model.voiceEnabled {
                    Text(model.voiceSnapshot.userPartial)
                        .font(.caption)
                        .lineLimit(2)
                        .padding(6)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(8)
                }
            }

            // Caption: what Aitvaras is saying, in text — always visible so
            // it can be read when the volume is down or the room is muted.
            if !model.voiceSnapshot.assistantText.isEmpty {
                ScrollView {
                    Text(model.voiceSnapshot.assistantText)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 110)
                .padding(8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(stateColor.opacity(0.4)))
                .padding(.horizontal, 4)
            }

            HStack(spacing: 14) {
                Button {
                    model.toggleVoice()
                } label: {
                    Image(systemName: model.voiceEnabled ? "mic.fill" : "mic")
                        .font(.title3)
                        .foregroundStyle(model.voiceEnabled ? .red : .primary)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(.ultraThinMaterial))
                }
                .buttonStyle(.plain)
                .help(model.voiceEnabled ? "Stop voice conversation" : "Start voice conversation")

                Text(stateLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 60)

                Button {
                    let current = UserDefaults.standard.string(forKey: "voice.locale") ?? "en-US"
                    model.setVoiceLanguage(current.hasPrefix("en") ? "de-DE" : "en-US")
                    languageRefresh.toggle()
                } label: {
                    Text((UserDefaults.standard.string(forKey: "voice.locale") ?? "en-US").hasPrefix("en") ? "EN" : "DE")
                        .font(.caption.weight(.semibold).monospaced())
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(.ultraThinMaterial))
                }
                .buttonStyle(.plain)
                .help("Speech recognition language (tap to switch)")
                .id(languageRefresh)

                if model.integrations?.focusCoach?.isEnabled == true {
                    Button {
                        model.toggleFocusSession()
                    } label: {
                        Image(systemName: model.focusSessionActive ? "moon.fill" : "moon")
                            .foregroundStyle(model.focusSessionActive ? .indigo : .primary)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(.ultraThinMaterial))
                    }
                    .buttonStyle(.plain)
                    .help(model.focusSessionActive ? "End focus session" : "Start focus session")
                }

                Button {
                    model.toggleCapture()
                } label: {
                    Image(systemName: model.captureActive ? "record.circle.fill" : "record.circle")
                        .foregroundStyle(model.captureActive ? .red : .primary)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(.ultraThinMaterial))
                }
                .buttonStyle(.plain)
                .help(model.captureActive
                    ? "Aufnahme beenden (Zusammenfassung wird erstellt)"
                    : "Aufnahme starten (Meeting/Vorlesung/Video transkribieren)")

                Button {
                    openWindow(id: "main")
                    NSApp.activate()
                } label: {
                    Image(systemName: "rectangle.expand.diagonal")
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(.ultraThinMaterial))
                }
                .buttonStyle(.plain)
                .help("Open Aitvaras")
            }
            .opacity(controlsVisible ? 1 : 0)
            .allowsHitTesting(controlsVisible)

            // Typed prompts, spoken answers — for when the mic is not an
            // option (working with others around). ⌥Space double-tap
            // focuses this field.
            TextField("Type to Aitvaras…", text: $typedPrompt)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($promptFocused)
                .onSubmit {
                    model.askCompanion(typedPrompt)
                    typedPrompt = ""
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(.ultraThinMaterial))
                .padding(.horizontal, 4)
                .onChange(of: model.companionFocusRequest) {
                    promptFocused = true
                }
                .opacity(controlsVisible ? 1 : 0)
                .allowsHitTesting(controlsVisible)

            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.1")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Slider(value: $volume, in: 0...2) { editing in
                    if !editing { VoiceVolume.gain = Float(volume) }
                }
                .controlSize(.mini)
                .frame(width: 110)
                Image(systemName: "speaker.wave.3")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 4)
            .opacity(controlsVisible ? 1 : 0)
            .allowsHitTesting(controlsVisible)

            if let message = model.voiceSnapshot.errorMessage ?? model.voiceSnapshot.statusMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(model.voiceSnapshot.errorMessage != nil ? .red : .secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .padding(6)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(8)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.18), value: controlsVisible)
    }

    private var stateColor: Color {
        switch model.characterState {
        case .idle: .gray
        case .listening: .teal
        case .thinking: .orange
        case .speaking: .green
        }
    }

    private var stateLabel: String {
        switch model.characterState {
        case .idle: "idle"
        case .listening: "listening…"
        case .thinking: "thinking…"
        case .speaking: "speaking"
        }
    }
}
