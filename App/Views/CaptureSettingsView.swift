import SwiftUI
import Speech
import AitvarasCore
import AitvarasEngines
import AitvarasVoice
import AitvarasStore

/// Shared by Settings and the pre-capture confirmation. Reading readiness
/// never installs assets; downloads only begin after an explicit button press.
@MainActor
@Observable
final class SpeechAssetReadiness {
    static let shared = SpeechAssetReadiness()

    enum Status: Equatable {
        case checking, ready, missing, unsupported, downloading
        case failed(String)
    }

    private(set) var statuses: [CaptureLanguage: Status] = [:]
    private var refreshInProgress = false
    private var tasks: [CaptureLanguage: Task<Void, Never>] = [:]
    private var operations: [CaptureLanguage: UUID] = [:]

    func refresh() async {
        guard !refreshInProgress else { return }
        refreshInProgress = true
        defer { refreshInProgress = false }
        for language in CaptureLanguage.allCases {
            guard statuses[language] != .downloading else { continue }
            let status = await installedStatus(for: language)
            // A user may start installation while this read is suspended.
            guard statuses[language] != .downloading else { continue }
            statuses[language] = status
        }
    }

    func download(_ language: CaptureLanguage, reporter: ActivityReporter? = nil) {
        guard statuses[language] != .downloading else { return }
        statuses[language] = .downloading
        let operation = reporter?.begin(ActivityRun(category: .model,
            title: "Install speech assets", stage: "Downloading and installing selected language",
            provider: "Apple Speech", executionLocation: "This Mac",
            dataAccess: "Public language assets", dataDestination: "Apple asset servers; no audio or transcript"))
        operations[language] = operation
        tasks[language] = Task {
            defer { tasks[language] = nil; operations[language] = nil }
            do {
                let supported = try await TranscriberSession.ensureModel(locale: language.locale)
                try Task.checkCancellation()
                statuses[language] = supported ? await installedStatus(for: language) : .unsupported
                if let operation { reporter?.finish(id: operation, state: statuses[language] == .ready ? .succeeded : .failed,
                    outcome: statuses[language] == .ready ? "Selected speech assets installed" : "Speech assets unavailable; readiness can be checked again") }
            } catch {
                statuses[language] = .failed(error is CancellationError ? "Installation was cancelled; refresh readiness before retrying." : error.localizedDescription)
                if let operation { reporter?.finish(id: operation, state: error is CancellationError ? .cancelled : .failed,
                    outcome: "Speech installation did not complete; existing assets retained") }
            }
        }
    }

    func stopBeforeTermination(reporter: ActivityReporter?) async {
        let pending = Array(tasks.values)
        for task in pending { task.cancel() }
        do { try await AsyncDeadline.run(for: .seconds(2)) { for task in pending { await task.value } } }
        catch {
            for operation in operations.values {
                reporter?.finish(id: operation, state: .interrupted,
                    outcome: "App closed before installation acknowledged stopping; recheck Apple asset readiness")
            }
        }
    }

    private func installedStatus(for language: CaptureLanguage) async -> Status {
        guard SpeechTranscriber.isAvailable,
              let supported = await SpeechTranscriber.supportedLocale(equivalentTo: language.locale) else {
            return .unsupported
        }
        let installed = await SpeechTranscriber.installedLocales
        return installed.contains(where: { $0.identifier == supported.identifier }) ? .ready : .missing
    }
}

struct CaptureSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var settings = CaptureSettings.load()
    @State private var speechAssets = SpeechAssetReadiness.shared
    @State private var summaryModel = "Checking local model…"
    @State private var summaryAvailable: Bool?
    @State private var manageAudio = false

    var body: some View {
        Group {
        if manageAudio {
            Section {
                CaptureAudioStorageView(onDone: { manageAudio = false })
            }
        } else {
        Section("Transcription") {
            LabeledContent("Backend", value: "Apple Speech · on this Mac")
            Text("Live captions run on this Mac; audio is discarded by default and never sent to cloud transcription.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Capture language", selection: $settings.language) {
                ForEach(CaptureLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            DisclosureGroup("Transcription details") {
                Text("Apple's on-device speech recognition provides live capture captions. Audio is discarded by default; optional source retention below enables a later local second pass. No audio is sent to a cloud transcription service.")
                Text("Applies to the next capture, independently of the companion's EN/DE conversation language.")
            }
            .font(.caption).foregroundStyle(.secondary)
            ForEach(CaptureLanguage.allCases) { language in
                speechAssetRow(language)
            }
            Button("Refresh speech readiness") { Task { await speechAssets.refresh() } }
                .controlSize(.small)
        }
        Section("After capture") {
            Picker("Processing", selection: $settings.postprocessing) {
                Text("Local summary + transcript").tag(CapturePostprocessing.localSummary)
                Text("Transcript only · no summary inference").tag(CapturePostprocessing.transcriptOnly)
            }
            if settings.postprocessing == .localSummary {
                LabeledContent("Local summary model", value: summaryModel)
                if summaryAvailable == false {
                    Label("No local summary model is available. The transcript can still be saved; its summary can be retried later.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Text("Save the transcript with an optional local summary.")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Processing details") {
                if settings.postprocessing == .localSummary {
                    Text("Uses the Background model selected in Local intelligence. The transcript is saved before summarization.")
                } else {
                    Text("Save the transcript and recognized screen text without starting a summary model. You can copy or export the saved text immediately.")
                }
                Text("Claude and Codex capture summaries are planned, but are not connected or available here.")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        Section("Optional source audio") {
            CaptureAudioRetentionOptions(retention: $settings.audioRetention)
            Button("Manage retained audio…") { manageAudio = true }
        }
        Section("Local second-pass transcription") {
            Text("Optional models refine retained audio on this Mac without changing live captions.")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Second-pass details") {
                Text("Apple Speech still provides live captions. These optional models re-transcribe retained audio afterwards, on this Mac, without changing the live transcript. They load only when you request a second pass.")
                Text("Qwen3-ASR is the quality-first candidate for multilingual lectures; Whisper Turbo is the faster alternative. Actual accuracy depends on the recording. Downloading weights sends no capture content.")
            }
            .font(.caption).foregroundStyle(.secondary)
            ForEach(CaptureRefinementModel.allCases) { choice in CaptureRefinementDownloadRow(modelChoice: choice) }
        }
        }
        }
        .onChange(of: settings) { settings.save() }
        .task {
            settings = CaptureSettings.load()
            await speechAssets.refresh()
            await refreshSummaryModel()
        }
        .onChange(of: model.modelDownloads.completionRevision) {
            Task { await refreshSummaryModel() }
        }
    }

    @ViewBuilder
    private func speechAssetRow(_ language: CaptureLanguage) -> some View {
        HStack(alignment: .top, spacing: 10) {
            let status = speechAssets.statuses[language] ?? .checking
            VStack(alignment: .leading, spacing: 3) {
                Text(language.displayName).font(.callout.weight(.medium))
                Text(statusLabel(status)).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            switch status {
            case .checking, .downloading:
                ProgressView().controlSize(.small)
                    .accessibilityLabel(status == .checking ? "Checking speech readiness" : "Downloading and installing speech assets")
            case .ready:
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            case .missing:
                Button("Download") { speechAssets.download(language, reporter: model.activityReporter) }.controlSize(.small)
            case .failed:
                Button("Retry") { speechAssets.download(language, reporter: model.activityReporter) }.controlSize(.small)
            case .unsupported:
                Label("Unavailable", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func statusLabel(_ status: SpeechAssetReadiness.Status) -> String {
        switch status {
        case .checking: "Checking support and installed assets…"
        case .ready: "Supported · speech assets installed"
        case .missing: "Supported · speech assets not installed"
        case .unsupported: "Apple Speech does not support this language on this Mac."
        case .downloading: "Downloading and installing Apple's speech assets… Progress percentage is not available."
        case .failed(let message): "Installation failed: \(message)"
        }
    }

    private func refreshSummaryModel() async {
        let engine = await model.router?.engineDescription(for: .background) ?? "none"
        switch engine {
        case "mlx":
            summaryModel = "MLX · \(MLXEngine.assignedModel(for: .background))"
            summaryAvailable = true
        case "ollama":
            summaryModel = "Ollama · \(model.captureOllamaModelName ?? "configured local model")"
            summaryAvailable = true
        default:
            summaryModel = "Unavailable · selected MLX model: \(MLXEngine.assignedModel(for: .background))"
            summaryAvailable = false
        }
    }
}
