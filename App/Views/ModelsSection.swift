import SwiftUI
import AitvarasCore
import AitvarasEngines

/// Model management (D2 revised): one model per role — chat wants depth,
/// voice wants speed, background automation wants accuracy. Models load
/// on demand; an LRU eviction keeps combined RAM in budget.
struct ModelsSection: View {
    @Environment(AppModel.self) private var model
    @State private var installed: [String] = MLXEngine.installedModels()
    @State private var assignments: [ModelTier: String] = currentAssignments()
    @State private var downloadStatus: [String: String] = [:]
    @State private var downloading = false

    /// Curated Qwen3 line-up — same family so templates/tool-calling stay
    /// consistent. Sizes are 4-bit MLX.
    static let catalog: [(repo: String, dir: String, size: String, hint: String)] = [
        ("mlx-community/Qwen3-1.7B-4bit", "Qwen3-1.7B-4bit", "1.1 GB", "fastest, simple replies"),
        ("mlx-community/Qwen3-4B-4bit", "Qwen3-4B-4bit", "2.2 GB", "fast, good voice default"),
        ("mlx-community/Qwen3-8B-4bit", "Qwen3-8B-4bit", "4.6 GB", "balanced"),
        ("mlx-community/Qwen3-14B-4bit", "Qwen3-14B-4bit", "8.2 GB", "strong, still snappy"),
        ("mlx-community/Qwen3-30B-A3B-4bit", "Qwen3-30B-A3B-4bit", "17 GB", "best quality (MoE, fast for its size)")
    ]

    var body: some View {
        Section("Models") {
            ForEach(ModelTier.allCases, id: \.self) { role in
                Picker(roleLabel(role), selection: Binding(
                    get: { assignments[role] ?? MLXEngine.assignedModel(for: role) },
                    set: { newValue in
                        assignments[role] = newValue
                        MLXEngine.assign(model: newValue, to: role)
                    })) {
                    ForEach(installed, id: \.self) { name in
                        Text(displayName(name)).tag(name)
                    }
                }
            }
            Text("Models load on first use and stay warm. Combined RAM is managed automatically (least-recently-used unloads first). Background handles mail triage and focus checks — its summaries are simply spoken by the voice pipeline, so a big background model doesn't slow conversations.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            DisclosureGroup("Download more models") {
                ForEach(Self.catalog, id: \.dir) { entry in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(displayName(entry.dir))
                            Text("\(entry.size) · \(entry.hint)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if installed.contains(entry.dir) {
                            if let status = downloadStatus[entry.dir] {
                                Text(status).font(.caption).foregroundStyle(.secondary)
                            } else {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green.opacity(0.7))
                                if !assignments.values.contains(entry.dir) {
                                    Button("Delete") { delete(entry.dir) }
                                        .controlSize(.small)
                                }
                            }
                        } else {
                            Button(downloadStatus[entry.dir] ?? "Download") {
                                download(entry)
                            }
                            .controlSize(.small)
                            .disabled(downloading)
                        }
                    }
                }
            }
        }
    }

    private func roleLabel(_ role: ModelTier) -> String {
        switch role {
        case .chat: "Chat (typed, deep work)"
        case .voice: "Voice (spoken, low latency)"
        case .background: "Background (mail triage, automations)"
        }
    }

    private func displayName(_ dir: String) -> String {
        dir.replacingOccurrences(of: "-4bit", with: "")
    }

    private static func currentAssignments() -> [ModelTier: String] {
        Dictionary(uniqueKeysWithValues: ModelTier.allCases.map { ($0, MLXEngine.assignedModel(for: $0)) })
    }

    private func download(_ entry: (repo: String, dir: String, size: String, hint: String)) {
        downloading = true
        downloadStatus[entry.dir] = "Downloading…"
        let python = NeuralVoicePaths.venvPython
        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = ["-c", """
                from huggingface_hub import snapshot_download
                import os
                snapshot_download("\(entry.repo)", local_dir=os.path.expanduser(
                    "~/Library/Application Support/Aitvaras/Models/\(entry.dir)"), max_workers=4)
                """]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                let ok = process.terminationStatus == 0
                await MainActor.run {
                    downloading = false
                    downloadStatus[entry.dir] = ok ? nil : "Failed — is the voice env installed?"
                    installed = MLXEngine.installedModels()
                }
            } catch {
                await MainActor.run {
                    downloading = false
                    downloadStatus[entry.dir] = "Failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func delete(_ dir: String) {
        try? FileManager.default.removeItem(
            at: MLXEngine.modelsDirectory().appendingPathComponent(dir))
        installed = MLXEngine.installedModels()
    }
}

/// Shared paths for the Python helper environment.
enum NeuralVoicePaths {
    static var venvPython: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aitvaras/voice-venv/bin/python").path
    }
}
