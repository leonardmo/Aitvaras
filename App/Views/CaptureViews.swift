import AppKit
import SwiftUI
@preconcurrency import ScreenCaptureKit
import AitvarasStore

/// Windows for capture setup and results — plain NSWindows managed here so
/// they can be opened from anywhere (companion button, agent tool) without
/// SwiftUI scene plumbing.
@MainActor
final class CaptureWindows {
    static let shared = CaptureWindows()
    private var setupWindow: NSWindow?
    private var resultWindow: NSWindow?

    func showSetup(model: AppModel) {
        setupWindow?.close()
        let window = makeWindow(title: "Aufnahme starten", size: NSSize(width: 460, height: 560))
        window.contentView = NSHostingView(rootView: CaptureSetupView(onClose: { [weak window] in
            window?.close()
        }).environment(model))
        setupWindow = window
        present(window)
    }

    func showResult(record: CaptureRecord, model: AppModel) {
        resultWindow?.close()
        let window = makeWindow(title: "Aufnahme: \(record.title)", size: NSSize(width: 640, height: 640))
        window.contentView = NSHostingView(rootView: CaptureResultView(record: record, onClose: { [weak window] in
            window?.close()
        }).environment(model))
        resultWindow = window
        present(window)
    }

    private func makeWindow(title: String, size: NSSize) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        return window
    }

    private func present(_ window: NSWindow) {
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

// MARK: - Setup

/// What/whether to capture — window, whole display, or audio only; which
/// audio; and the consent confirmation that gates the start button (O13).
private struct CaptureSetupView: View {
    @Environment(AppModel.self) private var model
    let onClose: () -> Void

    private enum ScopeChoice: Hashable {
        case audioOnly
        case display(Int)   // index into displays
        case window(Int)    // index into windows
    }

    @State private var displays: [SCDisplay] = []
    @State private var windows: [SCWindow] = []
    @State private var loadFailed = false
    @State private var scope: ScopeChoice = .audioOnly
    @State private var audio: CaptureController.AudioMode = .system
    @State private var title = ""
    @State private var consent = false
    @State private var errorMessage: String?
    @State private var starting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Was soll aufgenommen werden?")
                .font(.title3.weight(.semibold))
            Text("Es wird nie Audio oder Video gespeichert — nur der transkribierte Text und erkannter Bildschirmtext.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if loadFailed {
                Label("Bildschirmaufnahme nicht erlaubt — in Systemeinstellungen → Datenschutz → Bildschirmaufnahme freigeben, dann erneut öffnen.",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            Picker("Bildschirm", selection: $scope) {
                Text("Kein Bildschirm (nur Audio)").tag(ScopeChoice.audioOnly)
                ForEach(Array(displays.enumerated()), id: \.offset) { index, display in
                    Text("Ganzer Bildschirm \(index + 1) (\(display.width)×\(display.height))")
                        .tag(ScopeChoice.display(index))
                }
                ForEach(Array(windows.enumerated()), id: \.offset) { index, window in
                    Text(windowLabel(window)).tag(ScopeChoice.window(index))
                }
            }

            Picker("Audio", selection: $audio) {
                ForEach(CaptureController.AudioMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            if audio == .systemAndMic && model.voiceEnabled {
                Text("Das Mikrofon ist gerade durch die Sprachkonversation belegt.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            TextField("Titel (optional, z. B. \"Analysis-Vorlesung\")", text: $title)
                .textFieldStyle(.roundedBorder)

            Toggle(isOn: $consent) {
                Text("Alle aufgezeichneten Personen wissen von der Aufnahme und sind einverstanden.")
                    .font(.callout)
            }
            .toggleStyle(.checkbox)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Spacer()
            HStack {
                Spacer()
                Button("Abbrechen") { onClose() }
                    .keyboardShortcut(.escape)
                Button(starting ? "Starte…" : "Aufnahme starten") { start() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid || starting)
            }
        }
        .padding(20)
        .frame(width: 460, height: 560)
        .task { await loadContent() }
    }

    private var isValid: Bool {
        consent && !(scope == .audioOnly && audio == .none)
            && !(audio == .systemAndMic && model.voiceEnabled)
    }

    private func windowLabel(_ window: SCWindow) -> String {
        let app = window.owningApplication?.applicationName ?? "?"
        let title = window.title ?? ""
        return title.isEmpty ? app : "\(app) — \(String(title.prefix(40)))"
    }

    private func loadContent() async {
        do {
            // First call triggers the Screen Recording permission prompt.
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
            displays = content.displays
            windows = content.windows.filter { window in
                window.frame.width > 320 && window.frame.height > 240
                    && window.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier
            }
        } catch {
            loadFailed = true
        }
    }

    private func start() {
        guard let controller = model.capture else { return }
        let screenScope: CaptureController.ScreenScope = switch scope {
        case .audioOnly: .none
        case .display(let index): displays.indices.contains(index) ? .display(displays[index]) : .none
        case .window(let index): windows.indices.contains(index) ? .window(windows[index]) : .none
        }
        starting = true
        Task {
            do {
                try await controller.start(config: .init(
                    scope: screenScope, audio: audio,
                    title: title, consentConfirmed: consent))
                onClose()
            } catch {
                errorMessage = error.localizedDescription
            }
            starting = false
        }
    }
}

// MARK: - Result

private struct CaptureResultView: View {
    @Environment(AppModel.self) private var model
    let record: CaptureRecord
    let onClose: () -> Void
    @State private var showTranscript = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.title).font(.title3.weight(.semibold))
                    Text("\(record.scope) · \(record.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(durationLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !record.consentConfirmed {
                    Label("Einverständnis nicht bestätigt", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            ScrollView {
                if record.summaryPending {
                    Label("Zusammenfassung ausstehend (kein Modell verfügbar) — Transkript ist gesichert.",
                          systemImage: "clock")
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(LocalizedStringKey(record.summary))   // renders the markdown
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                if showTranscript {
                    Divider().padding(.vertical, 6)
                    Text(record.transcript)
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))

            HStack {
                Toggle("Transkript anzeigen", isOn: $showTranscript)
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Kopieren") {
                    let markdown = "# \(record.title)\n\n\(record.summary)\n\n## Transkript\n\n\(record.transcript)"
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(markdown, forType: .string)
                }
                Button("Löschen", role: .destructive) {
                    try? model.stores?.deleteCaptureRecord(record.id)
                    onClose()
                }
                Button("Fertig") { onClose() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.escape)
            }
        }
        .padding(16)
        .frame(width: 640, height: 640)
    }

    private var durationLabel: String {
        let minutes = max(1, Int(record.endedAt.timeIntervalSince(record.startedAt) / 60))
        return "\(minutes) min"
    }
}
