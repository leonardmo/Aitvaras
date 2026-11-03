import AppKit
import SwiftUI
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers
import AitvarasCore
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
        let window = makeWindow(title: "Aufnahme starten", size: NSSize(width: 560, height: 780))
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

    func showSaveError(_ error: Error) {
        NotificationRouter.requestedWorkNeedsAttention()
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Aufnahme konnte nicht gespeichert werden"
        alert.informativeText = "Das Transkript bleibt vorläufig im Speicher. Bitte klicke erneut auf Stopp, bevor du eine neue Aufnahme startest.\n\n\(error.localizedDescription)"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func makeWindow(title: String, size: NSSize) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = title
        window.minSize = NSSize(width: min(size.width, 520), height: 480)
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
struct CaptureSetupView: View {
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
    @State private var loadingScreens = false
    @State private var scope: ScopeChoice = .audioOnly
    @State private var audio: CaptureController.AudioMode = .microphone
    @State private var title = ""
    @State private var consent = false
    @State private var errorMessage: String?
    @State private var starting = false
    @State private var startupTask: Task<Void, Never>?
    @State private var captureSettings = CaptureSettings.load()
    @State private var showSettings = false
    @State private var speechAssets = SpeechAssetReadiness.shared
    @State private var targetProjects: [WorkspaceProject] = []
    @State private var targetChats: [UUID: [WorkspaceChat]] = [:]
    @State private var targetProjectID: UUID?
    @State private var targetChatID: UUID?
    @State private var loadingTargets = true
    @State private var targetLoadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView {
            VStack(alignment: .leading, spacing: 14) {
            Text("Was soll aufgenommen werden?")
                .font(.title3.weight(.semibold))
            Text("Standardmäßig werden nur Transkript und erkannter Bildschirmtext gespeichert. Optional kannst du Audio für eine spätere lokale Transkription behalten. Video wird nie gespeichert.")
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
            Button(loadingScreens ? "Lade Bildschirme…" : "Bildschirme/Fenster laden…") {
                Task { await loadContent() }
            }.disabled(loadingScreens)
            Text("Optional: Erst dieser Knopf fragt die Bildschirmfreigabe an. Nur Mikrofon benötigt sie nicht.")
                .font(.caption).foregroundStyle(.secondary)

            Picker("Audio", selection: $audio) {
                ForEach(CaptureController.AudioMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            Text("Mikrofon und Systemaudio werden getrennt transkribiert und im Text gekennzeichnet. Das Mikrofon kann auch die Vorlesung oder mehrere Personen im Raum hören. Einzelne Sprecher werden noch nicht erkannt.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Während der Aufnahme wird automatischer Systemruhezustand verhindert; ohne Bildschirmaufnahme darf das Display schlafen. Zuklappen oder erzwungener Ruhezustand kann Lücken verursachen. Nach Stopp endet der Schutz.")
                .font(.caption).foregroundStyle(.secondary)
            if starting, let capture = model.capture {
                Label(capture.sleepProtectionSummary, systemImage: "moon.zzz")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if audio.usesMicrophone && model.microphoneInUseByVoice {
                Text("Das Mikrofon ist gerade durch die Sprachkonversation belegt.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            TextField("Titel (optional, z. B. \"Analysis-Vorlesung\")", text: $title)
                .textFieldStyle(.roundedBorder)

            Divider()
            captureDestination
            Divider()
            LabeledContent("Transkription", value: "Apple Speech · auf diesem Mac")
                .font(.callout)
            Picker("Aufnahmesprache", selection: $captureSettings.language) {
                ForEach(CaptureLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            Text("Unabhängig von der EN/DE-Sprache der Sprachkonversation. Gilt für diese und die nächsten Aufnahmen.")
                .font(.caption).foregroundStyle(.secondary)
            selectedSpeechReadiness
            Picker("Nach der Aufnahme", selection: $captureSettings.postprocessing) {
                Text("Lokale Zusammenfassung + Transkript").tag(CapturePostprocessing.localSummary)
                Text("Nur Transkript · ohne Zusammenfassungsmodell").tag(CapturePostprocessing.transcriptOnly)
            }
            Button("Transkriptions- und Modelleinstellungen…") { showSettings = true }
                .controlSize(.small)
            Divider()

            CaptureAudioRetentionOptions(retention: $captureSettings.audioRetention)
                .disabled(audio == .none)
            if audio == .none {
                Text("Ohne Audioquelle werden keine Audiodateien gespeichert.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()

            Toggle(isOn: $consent) {
                Text(captureSettings.audioRetention == .discard || audio == .none
                     ? "Alle aufgezeichneten Personen wissen von der Aufnahme und sind einverstanden."
                     : "Alle aufgezeichneten Personen wissen, dass Audio lokal gespeichert wird, und sind einverstanden.")
                    .font(.callout)
            }
            .toggleStyle(.checkbox)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()
            HStack {
                Spacer()
                Button("Abbrechen") {
                    startupTask?.cancel()
                    if starting { model.capture?.cancelStartup() }
                    onClose()
                }
                    .keyboardShortcut(.escape)
                Button(starting ? "Starte…" : "Aufnahme starten") { start() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid || starting)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 480)
        .onChange(of: captureSettings) { captureSettings.save() }
        .onChange(of: captureSettings.audioRetention) { consent = false }
        .onChange(of: audio) { consent = false }
        .onChange(of: targetProjectID) { targetChatID = nil }
        .onDisappear {
            startupTask?.cancel()
            if starting { model.capture?.cancelStartup() }
        }
        .task {
            loadCaptureTargets()
            await speechAssets.refresh()
        }
        .disabled(showSettings)
        .accessibilityHidden(showSettings)
        .overlay {
            if showSettings {
            VStack(spacing: 0) {
                Form { CaptureSettingsView() }.formStyle(.grouped)
                HStack { Spacer(); Button("Zurück zur Aufnahme") { showSettings = false; captureSettings = CaptureSettings.load() }.keyboardShortcut(.defaultAction) }
                    .padding()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            }
        }
    }

    @ViewBuilder private var captureDestination: some View {
        Text("Lokal speichern unter").font(.callout.weight(.semibold))
        Picker("Projekt", selection: $targetProjectID) {
            Text("Nicht zugeordnet").tag(nil as UUID?)
            ForEach(targetProjects) { project in
                Text(project.title).tag(Optional(project.id))
            }
        }
        .disabled(starting || loadingTargets)
        if let targetProjectID {
            Picker("Primärer Chat", selection: $targetChatID) {
                Text("Chat auswählen…").tag(nil as UUID?)
                ForEach(targetChats[targetProjectID] ?? []) { chat in
                    Text(chat.title).tag(Optional(chat.id))
                }
            }
            .disabled(starting)
            if (targetChats[targetProjectID] ?? []).isEmpty {
                Text("Dieses Projekt hat keinen aktiven primären Chat. Lege zuerst einen an oder wähle „Nicht zugeordnet“.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        Text("Die Aufnahme bleibt als Aitvaras-Aufnahme lokal gespeichert. Eine Zuordnung verknüpft sie mit dem gewählten Projekt und Chat; sie sendet keine Nachricht an lokale oder native Chats und exportiert keine Datei. Das Ziel bleibt während der gesamten Aufnahme unverändert, auch wenn du den Chat wechselst.")
            .font(.caption).foregroundStyle(.secondary)
        if let targetLoadError {
            Text(targetLoadError).font(.caption).foregroundStyle(.orange)
            Button("Projektziele erneut laden") { loadCaptureTargets() }.controlSize(.small)
        }
    }

    private func loadCaptureTargets() {
        loadingTargets = true
        defer { loadingTargets = false }
        do {
            guard let stores = model.stores else {
                throw CaptureError("Lokaler Speicher ist nicht verfügbar.")
            }
            let projects = try stores.workspaceProjects(includeHidden: false)
            var chats: [UUID: [WorkspaceChat]] = [:]
            for project in projects {
                chats[project.id] = try stores.workspaceChats(projectID: project.id)
                    .filter { $0.kind == .primary && $0.archivedAt == nil }
            }
            targetProjects = projects
            targetChats = chats
            targetLoadError = nil
            // Deliberately do not restore a saved capture destination or follow
            // changes to the currently open chat. Each setup starts unassigned.
        } catch {
            targetLoadError = "Projektziele konnten nicht geladen werden. Nicht zugeordnete lokale Aufnahme bleibt möglich."
        }
    }

    @ViewBuilder private var selectedSpeechReadiness: some View {
        if audio != .none {
            let status = speechAssets.statuses[captureSettings.language] ?? .checking
            switch status {
            case .ready:
                Label("Sprachdateien installiert", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            case .checking:
                Label("Sprachdateien werden geprüft…", systemImage: "clock")
                    .font(.caption).foregroundStyle(.secondary)
            case .downloading:
                HStack { ProgressView().controlSize(.small); Text("Sprachdateien werden heruntergeladen und installiert…").font(.caption) }
            case .missing:
                Label("Sprachdateien fehlen. Bitte vor dem Start herunterladen.", systemImage: "arrow.down.circle")
                    .font(.caption).foregroundStyle(.orange)
                Button("Sprachdateien herunterladen") { speechAssets.download(captureSettings.language, reporter: model.activityReporter) }
                    .controlSize(.small)
            case .unsupported:
                Label("Diese Sprache wird von Apple Speech auf diesem Mac nicht unterstützt.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            case .failed(let message):
                Text("Sprachdateien konnten nicht installiert werden: \(message)")
                    .font(.caption).foregroundStyle(.red)
                Button("Installation erneut versuchen") { speechAssets.download(captureSettings.language, reporter: model.activityReporter) }
                    .controlSize(.small)
            }
        }
    }

    private var isValid: Bool {
        consent && !(scope == .audioOnly && audio == .none)
            && !loadingTargets && (targetProjectID == nil || selectedTargetChatID != nil)
            && !(audio.usesMicrophone && model.microphoneInUseByVoice)
            && (audio == .none || speechAssets.statuses[captureSettings.language] == .ready)
    }

    private var selectedTargetChatID: UUID? {
        guard let targetProjectID, let targetChatID,
              targetChats[targetProjectID]?.contains(where: { $0.id == targetChatID && $0.projectID == targetProjectID }) == true else { return nil }
        return targetChatID
    }

    private func windowLabel(_ window: SCWindow) -> String {
        let app = window.owningApplication?.applicationName ?? "?"
        let title = window.title ?? ""
        return title.isEmpty ? app : "\(app) — \(String(title.prefix(40)))"
    }

    private func loadContent() async {
        loadingScreens = true
        loadFailed = false
        defer { loadingScreens = false }
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
        captureSettings.save()
        let screenScope: CaptureController.ScreenScope = switch scope {
        case .audioOnly: .none
        case .display(let index): displays.indices.contains(index) ? .display(displays[index]) : .none
        case .window(let index): windows.indices.contains(index) ? .window(windows[index]) : .none
        }
        starting = true
        startupTask = Task {
            do {
                try await controller.start(config: .init(
                    scope: screenScope, audio: audio,
                    title: title, consentConfirmed: consent, targetChatID: selectedTargetChatID))
                starting = false
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
    let onClose: () -> Void
    @State private var record: CaptureRecord
    @State private var showTranscript = false
    @State private var retryingSummary = false
    @State private var retryError = ""
    @State private var linkedTarget: CaptureLinkedTarget?
    @State private var targetLookupError: String?

    init(record: CaptureRecord, onClose: @escaping () -> Void) {
        self.onClose = onClose
        _record = State(initialValue: record)
        _showTranscript = State(initialValue: record.summaryPending || record.summary.isEmpty)
    }

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

            if let linkedTarget {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Label("\(linkedTarget.projectTitle) → \(linkedTarget.chatTitle)", systemImage: "link")
                            .font(.callout)
                        Text("Lokale Aitvaras-Aufnahme · nur verknüpft, nicht als Chatnachricht gesendet oder automatisch exportiert.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Chat öffnen") {
                        model.openWorkspaceChat(linkedTarget.chatID)
                        guard model.selectedWorkspaceChatID == linkedTarget.chatID else { return }
                        NotificationCenter.default.post(name: Notification.Name("aitvaras.openWorkspaceChat"), object: nil)
                        onClose()
                    }
                    .disabled(!linkedTarget.canOpen || model.isWorkspaceSelectionBusy)
                }
            } else {
                Text(targetLookupError ?? "Lokal gespeicherte Aitvaras-Aufnahme · keinem Projekt zugeordnet. Kein automatischer Export.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if isLiveCheckpoint {
                Label("Aufnahme läuft noch · dies ist der zuletzt gespeicherte Zwischenstand.", systemImage: "record.circle")
                    .font(.callout).foregroundStyle(.orange)
                Text("Kopieren oder Exportieren enthält nur den bereits gesicherten Text und stoppt die Aufnahme nicht.")
                    .font(.caption).foregroundStyle(.secondary)
                if let capture = model.capture {
                    Label(capture.sleepProtectionSummary, systemImage: "moon.zzz")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if isRecordInProgress {
                Label(model.capture?.isRecordSummarizing(record.id) == true ? "Transkript gesichert · lokale Zusammenfassung läuft."
                      : model.capture?.isFinishing == true ? "Aufnahme gestoppt · Abschluss wird verarbeitet."
                      : "Aufnahme gestoppt · Abschluss muss erneut gespeichert werden.", systemImage: "clock")
                    .font(.callout).foregroundStyle(.orange)
                Text("Dieser gespeicherte Zwischenstand bleibt zum Kopieren und Exportieren verfügbar.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if record.transcript.isEmpty && record.summary.isEmpty {
                Label("Kein Transkript gespeichert · möglicherweise vor dem ersten Zwischenstand unterbrochen.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            } else if !record.summaryPending {
                Label(record.summary.isEmpty ? "Aufnahme beendet · Transkript gespeichert" : "Aufnahme beendet · Transkript und Zusammenfassung gespeichert",
                      systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if model.recentActivityRuns.contains(where: { $0.category == .capture && $0.referenceID == record.id.uuidString && [.interrupted, .outcomeUnknown].contains($0.state) }) {
                Label("Frühere Aufnahme oder Verarbeitung wurde unterbrochen. Der gespeicherte Text ist verfügbar; letzte Wörter oder Zusammenfassung können unvollständig sein.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                CaptureAudioArchiveView(recordID: record.id, originalTranscript: record.transcript)
                    .padding(.bottom, 10)
                if record.summaryPending {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(isLiveCheckpoint ? "Zusammenfassung nach dem Stoppen verfügbar."
                              : "Transkript gesichert · Zusammenfassung noch nicht abgeschlossen.",
                              systemImage: "clock")
                            .foregroundStyle(.orange)
                        Button(retryingSummary ? "Versuche erneut…" : "Lokal zusammenfassen / erneut versuchen") {
                            retrySummary()
                        }
                        .disabled(retryingSummary || isRecordInProgress || record.transcript.isEmpty)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if !record.summary.isEmpty {
                    Text(LocalizedStringKey(record.summary))   // renders the markdown
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                if showTranscript || record.summary.isEmpty {
                    Divider().padding(.vertical, 6)
                    Text(record.transcript)
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))

            if !retryError.isEmpty {
                Text(retryError).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Toggle("Transkript anzeigen", isOn: $showTranscript)
                    .toggleStyle(.checkbox)
                    .disabled(record.summary.isEmpty)
                Spacer()
                if !record.summaryPending && record.summary.isEmpty {
                    Button(retryingSummary ? "Fasse lokal zusammen…" : "Lokal zusammenfassen") { retrySummary() }
                        .disabled(retryingSummary || isRecordInProgress || record.transcript.isEmpty)
                }
            }
            HStack {
                Menu("Kopieren") {
                    Button("Nur Transkript") { copy(record.transcript) }
                    Button("Aufnahme als Markdown") { copy(markdown) }
                }
                Menu("Exportieren…") {
                    Button("Transkript als Textdatei…") { export(transcriptOnly: true) }
                    Button("Aufnahme als Markdown…") { export(transcriptOnly: false) }
                }
                Spacer()
                Button("Löschen", role: .destructive) {
                    Task {
                        do {
                            try await model.deleteCaptureAndArtifacts(record.id)
                            onClose()
                        } catch {
                            model.presentError(title: "Capture could not be deleted", error: error)
                        }
                    }
                }
                .disabled(retryingSummary || model.capture?.canDeleteRecord(record.id) == false ||
                          (model.captureRefinement.isProcessing && model.captureRefinement.activeArchiveID == record.id))
                Button("Fertig") { onClose() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.escape)
            }
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 480)
        .task { reloadTarget() }
        .onReceive(NotificationCenter.default.publisher(for: .aitvarasCaptureRecordsChanged).receive(on: RunLoop.main)) { _ in
            reloadRecord()
        }
    }

    private var isLiveCheckpoint: Bool {
        model.capture?.isActive == true && model.capture?.isRecordBeingCaptured(record.id) == true
    }

    private var isRecordInProgress: Bool {
        model.capture?.isRecordInProgress(record.id) == true
    }

    private var markdown: String {
        var text = "# \(record.title)\n\n"
        if !record.summary.isEmpty { text += "\(record.summary)\n\n" }
        text += "## Transkript\n\n\(record.transcript)"
        return text
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func export(transcriptOnly: Bool) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = transcriptOnly ? [.plainText] : [UTType(filenameExtension: "md") ?? .plainText]
        let safeTitle = record.title.components(separatedBy: CharacterSet(charactersIn: "/:\n\r")).joined(separator: "-")
        panel.nameFieldStringValue = "\(safeTitle.isEmpty ? "Aufnahme" : safeTitle).\(transcriptOnly ? "txt" : "md")"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try (transcriptOnly ? record.transcript : markdown).write(to: destination, atomically: true, encoding: .utf8)
        } catch {
            model.presentError(title: "Transkript konnte nicht exportiert werden", error: error)
        }
    }

    private func reloadRecord() {
        do {
            if let saved = try model.stores?.captureRecord(id: record.id) { record = saved }
            else { onClose() }
            reloadTarget()
        } catch {
            retryError = "Gespeicherter Stand konnte nicht aktualisiert werden: \(error.localizedDescription)"
        }
    }

    private struct CaptureLinkedTarget {
        let chatID: UUID
        let projectTitle: String
        let chatTitle: String
        let canOpen: Bool
    }

    private func reloadTarget() {
        do {
            guard let stores = model.stores else { throw CaptureError("Lokaler Speicher ist nicht verfügbar.") }
            if let target = try stores.workspaceCaptureTarget(recordID: record.id) {
                let project = try stores.workspaceProject(id: target.projectID)
                let chat = try stores.workspaceChat(id: target.chatID)
                linkedTarget = CaptureLinkedTarget(chatID: target.chatID,
                    projectTitle: (project?.title ?? "Nicht verfügbares Projekt") + (project?.isVisible == false ? " (ausgeblendet)" : ""),
                    chatTitle: (chat?.title ?? "Nicht verfügbarer Chat") + (chat?.archivedAt != nil ? " (archiviert)" : ""),
                    canOpen: project?.isVisible == true && chat != nil)
            } else {
                linkedTarget = nil
            }
            targetLookupError = nil
        } catch {
            linkedTarget = nil
            targetLookupError = "Die gespeicherte Projekt-/Chatzuordnung konnte nicht geladen werden. Sie wurde nicht verändert."
        }
    }

    private var durationLabel: String {
        let minutes = max(1, Int(record.endedAt.timeIntervalSince(record.startedAt) / 60))
        return "\(minutes) min"
    }

    private func retrySummary() {
        guard let capture = model.capture else { return }
        retryingSummary = true
        retryError = ""
        Task {
            do {
                record = try await capture.retrySummary(for: record.id)
            } catch {
                retryError = error.localizedDescription
            }
            retryingSummary = false
        }
    }
}
