import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AitvarasCore

extension Notification.Name {
    static let aitvarasCaptureAudioChanged = Notification.Name("aitvarasCaptureAudioChanged")
}

struct CaptureAudioRetentionOptions: View {
    @Binding var retention: CaptureAudioRetention
    var body: some View {
        Picker("Keep source audio", selection: $retention) {
            ForEach(CaptureAudioRetention.allCases) { policy in
                Text(policy.displayLabel).tag(policy)
            }
        }
        Text(retention == .discard
             ? "Only text is saved. Later audio-based re-transcription will not be possible."
             : "Saves microphone and system audio separately on this Mac for later local re-transcription. No audio is uploaded. Applies only to new captures.")
            .font(.caption).foregroundStyle(.secondary)
        if retention != .discard {
            Label("Audio contains private conversations. Make sure participants consent to retaining it.", systemImage: "lock.shield")
                .font(.caption).foregroundStyle(.orange)
            Text("Uncompressed PCM16: approximately 0.35 GB/hour per mono 48 kHz source; stereo uses twice as much. Files are excluded from automatic system backups, not encrypted separately from your Mac.")
                .font(.caption).foregroundStyle(.secondary)
            if retention == .sevenDays {
                Text("Expires seven days after capture starts. Removal happens when Aitvaras next opens or this view is visited; a busy recording is never deleted.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Saved source audio and second-pass output remain independent of the live text.
struct CaptureAudioArchiveView: View {
    @Environment(AppModel.self) private var model
    let recordID: UUID
    let originalTranscript: String
    @State private var entry: CaptureAudioArchiveStore.Entry?
    @State private var checked = false
    @State private var error: String?
    @State private var selectedModel = CaptureRefinementModel.qwen3ASR17B8bit
    @State private var language = CaptureSettings.load().language
    @State private var confirmDeletion = false
    @State private var busy = false
    @State private var expanded = false
    private var refinement: CaptureRefinementManager { model.captureRefinement }
    private var processingThis: Bool { refinement.isProcessing && refinement.activeArchiveID == recordID }

    var body: some View {
        DisclosureGroup("Source audio & improved transcription", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 9) {
                if let entry {
                    archiveDetails(entry)
                } else if checked {
                    Text("No retained audio is available for this capture. Its live transcript is still saved, but an audio-based second pass cannot recover words that were never retained.")
                        .font(.caption).foregroundStyle(.secondary)
                } else { Text("Checking retained audio…").font(.caption).foregroundStyle(.secondary) }
                savedCandidate
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
        .task(id: recordID) { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: .aitvarasCaptureAudioChanged)) { _ in Task { await reload() } }
        .onReceive(NotificationCenter.default.publisher(for: .aitvarasCaptureRecordsChanged)) { _ in Task { await reload() } }
        .onChange(of: refinement.isProcessing) { if !refinement.isProcessing { Task { await reload() } } }
        .onChange(of: model.modelDownloads.completionRevision) { Task { await reload() } }
        .confirmationDialog("Delete retained audio?", isPresented: $confirmDeletion, titleVisibility: .visible) {
            Button("Delete source audio", role: .destructive) { deleteAudio() }
        } message: {
            Text("The original and refined transcripts remain. Re-transcription will no longer be possible from this audio. Exported copies are not affected.")
        }
    }

    @ViewBuilder private func archiveDetails(_ entry: CaptureAudioArchiveStore.Entry) -> some View {
        if let manifest = entry.manifest {
            HStack {
                Label(entry.isInterrupted ? "Interrupted audio · may be incomplete" : manifest.state == .finalized ? "Audio saved on this Mac" : manifest.state == .recording ? "Saving local source audio" : "Audio incomplete · inspect before use",
                      systemImage: manifest.state == .finalized ? "waveform" : "exclamationmark.triangle")
                    .foregroundStyle(manifest.state == .finalized ? Color.primary : .orange)
                Spacer()
                Text(manifest.retention.displayLabel).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(manifest.sources, id: \.source) { source in
                Text("\(source.source.displayLabel) · \(durationLabel(source)) · \(source.channels) channel(s)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let expiry = manifest.expiresAt {
                Text("Expiry: \(expiry.formatted(date: .abbreviated, time: .shortened)) · removal on next app/view visit")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if manifest.state == .finalized, !entry.isLeased {
                Picker("Second-pass model", selection: $selectedModel) {
                    ForEach(CaptureRefinementModel.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("Audio language", selection: $language) {
                    ForEach(CaptureLanguage.allCases) { Text($0.displayName).tag($0) }
                }
                if selectedModel.isInstalled() {
                    Button("Transcribe retained audio locally") {
                        guard model.canStartCaptureRefinement else {
                            error = "Finish current chat, voice, capture or model work first, then retry."
                            return
                        }
                        error = nil
                        refinement.start(archiveID: recordID, model: selectedModel, language: language)
                    }.disabled(!model.canStartCaptureRefinement)
                    if !model.canStartCaptureRefinement {
                        Text("Waiting for other local work to finish. Nothing starts automatically.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    CaptureRefinementDownloadRow(modelChoice: selectedModel)
                }
                Text("Runs on this Mac only. The live transcript stays unchanged. Window timestamps are approximate, not word-level alignment; source labels are not speaker detection.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Label("An incomplete audio archive was found. Export it for recovery; it will not be silently treated as a complete recording.", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        }
        if processingThis {
            Text(refinement.status ?? "Transcribing saved audio…").font(.caption)
            if let progress = refinement.progress { ProgressView(value: progress.fraction) }
            Button(refinement.isCancelling ? "Stopping after current window…" : "Stop second pass") { refinement.cancelActive() }
                .disabled(refinement.isCancelling)
        } else if refinement.lastArchiveID == recordID, let status = refinement.status {
            Text(status).font(.caption).foregroundStyle(.secondary)
        }
        HStack {
            Button("Export source audio…") { exportAudio() }.disabled(entry.isLeased || busy)
            Button("Delete audio…", role: .destructive) { confirmDeletion = true }.disabled(entry.isLeased || busy)
        }.controlSize(.small)
    }

    @ViewBuilder private var savedCandidate: some View {
        if let candidate = refinement.candidate, candidate.archiveID == recordID {
            Divider()
            if refinement.savedCandidates.count > 1 {
                Picker("Refined version", selection: Binding(get: { candidate.id }, set: { refinement.selectSavedCandidate($0) })) {
                    ForEach(refinement.savedCandidates) { version in
                        Text("\(version.model.displayName) · \(version.createdAt.formatted(date: .abbreviated, time: .shortened))").tag(version.id)
                    }
                }
            }
            Label("Refined transcript · \(candidate.model.displayName)", systemImage: "text.badge.checkmark")
                .font(.caption.weight(.semibold))
            Text("Existing capture summaries use the original live transcript. This separate refined version can be exported with the captured screen text for further work.")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Read refined text") {
                Text(candidate.rendered()).font(.caption.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Copy refined transcript") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(refinedDocument(candidate), forType: .string)
                }
                Button("Export refined Markdown…") { exportCandidate(candidate) }
            }.controlSize(.small)
        }
    }

    private func reload() async {
        let store = model.captureAudioArchives
        let result = await Task.detached { () -> CaptureAudioArchiveStore.Entry? in
            _ = try? store.deleteExpired()
            return try? store.inspect(recordID)
        }.value
        entry = result; checked = true
        await refinement.loadSaved(archiveID: recordID)
    }
    private func durationLabel(_ source: CaptureAudioManifest.Source) -> String {
        let seconds = Double(source.frameCount) / source.sampleRate
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "duration unavailable" }
        return "\(Int(seconds))s"
    }
    private func deleteAudio() {
        busy = true; error = nil
        let store = model.captureAudioArchives
        let operation = model.activityReporter?.begin(ActivityRun(referenceID: recordID.uuidString, category: .capture,
            title: "Delete retained source audio", stage: "Removing selected app-owned audio files",
            executionLocation: "This Mac", dataAccess: "Selected source audio", dataDestination: "Local deletion only"))
        Task {
            do {
                try await Task.detached { try store.delete(recordID) }.value
                if let operation { model.activityReporter?.finish(id: operation, state: .succeeded, outcome: "Source audio removed; saved text versions unchanged") }
            } catch {
                self.error = "Audio could not be deleted. Stop active processing and retry; unsafe files are left untouched."
                if let operation { model.activityReporter?.finish(id: operation, state: .failed, outcome: "Source audio deletion did not finish; inspect remaining files") }
            }
            busy = false
            await reload()
        }
    }
    private func exportAudio() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.canCreateDirectories = true; panel.prompt = "Export audio"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        busy = true; error = nil
        let store = model.captureAudioArchives
        let operation = model.activityReporter?.begin(ActivityRun(referenceID: recordID.uuidString, category: .capture,
            title: "Export retained source audio", stage: "Copying separate audio sources",
            executionLocation: "This Mac", dataAccess: "Selected source audio", dataDestination: "User-selected local folder"))
        Task {
            do {
                _ = try await Task.detached { try store.export(recordID, to: destination) }.value
                if let operation { model.activityReporter?.finish(id: operation, state: .succeeded, outcome: "Local audio copy exported; managed original unchanged") }
            } catch {
                self.error = "Audio export could not finish. Existing recordings were not removed."
                if let operation { model.activityReporter?.finish(id: operation, state: .failed, outcome: "Audio export did not finish; original recording retained") }
            }
            busy = false
        }
    }
    private func refinedDocument(_ candidate: CaptureRefinementCandidate) -> String {
        let screen = CaptureScreenText.extract(from: originalTranscript)
        return candidate.document + (screen.isEmpty ? "" : "\n\n## Screen text from original capture\n\n" + screen)
    }
    private func exportCandidate(_ candidate: CaptureRefinementCandidate) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "refined-transcript.md"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do { try refinedDocument(candidate).write(to: destination, atomically: true, encoding: .utf8) }
        catch { self.error = "The refined transcript could not be exported." }
    }
}

/// Includes orphan/interrupted archives, so retention never creates invisible
/// files merely because setup failed before a text capture record was saved.
struct CaptureAudioStorageView: View {
    @Environment(AppModel.self) private var model
    var onDone: () -> Void
    @State private var entries: [CaptureAudioArchiveStore.Entry] = []
    @State private var selected: CaptureAudioArchiveStore.Entry?
    @State private var failed = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let entry = selected {
                Button("Back to Recordings", systemImage: "chevron.left") {
                    selected = nil
                    Task { await reload() }
                }
                ScrollView {
                    CaptureAudioArchiveView(recordID: entry.id, originalTranscript: "")
                }
            } else {
            HStack { Text("Retained capture audio").font(.title3.weight(.semibold)); Spacer(); Button("Back to Settings", action: onDone) }
            Text("Local source recordings, including interrupted captures. Deleting audio here leaves text records and refined transcripts intact. Exported copies have their own retention.")
                .font(.caption).foregroundStyle(.secondary)
            List(entries) { entry in
                Button { selected = entry } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.manifest?.startedAt.formatted(date: .abbreviated, time: .shortened) ?? "Incomplete archive")
                            .font(.callout.weight(.medium))
                        Text(entry.isInterrupted ? "Interrupted · recovery/export available" : entry.manifest?.state.rawValue.capitalized ?? "Metadata unavailable")
                            .font(.caption).foregroundStyle(entry.isInterrupted ? .orange : .secondary)
                        Text(entry.manifest?.retention.displayLabel ?? "Unknown retention · not automatically deleted")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }.buttonStyle(.plain)
            }
            if entries.isEmpty { Text(failed ? "Audio storage could not be checked. Existing files were left untouched." : "No retained audio recordings.").font(.callout).foregroundStyle(.secondary) }
            }
        }
        .padding(20).frame(maxWidth: .infinity).frame(height: 500)
        .task { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: .aitvarasCaptureAudioChanged)) { _ in Task { await reload() } }
    }
    private func reload() async {
        let store = model.captureAudioArchives
        do {
            entries = try await Task.detached { _ = try store.deleteExpired(); return try store.list() }.value
            failed = false
        } catch { failed = true }
    }
}

struct CaptureRefinementDownloadRow: View {
    @Environment(AppModel.self) private var model
    let modelChoice: CaptureRefinementModel
    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(modelChoice.displayName).font(.callout)
                Text(model.modelDownloads.status[modelChoice.directoryName] ?? "\(ByteCountFormatter.string(fromByteCount: modelChoice.expectedBytes, countStyle: .file)) · public weights from Hugging Face · no audio uploaded")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.modelDownloads.activeModelID == modelChoice.directoryName {
                Button(model.modelDownloads.isCancelling ? "Pausing…" : "Pause") { model.modelDownloads.cancelActive() }
                    .disabled(model.modelDownloads.isCancelling)
            } else if modelChoice.isInstalled() {
                Label("Installed", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
            } else {
                Button("Download") {
                    model.modelDownloads.start(repository: modelChoice.repository, revision: modelChoice.revision,
                        modelID: modelChoice.directoryName, expectedBytes: modelChoice.expectedBytes)
                }.disabled(model.modelDownloads.activeModelID != nil)
            }
        }
    }
}
