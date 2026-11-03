import SwiftUI
import AitvarasCore
import AitvarasConnectors
import AitvarasEngines
import AitvarasAgent
import AitvarasStore

enum ModelsSetupPane: Hashable {
    case localModels, cloudAgents, memory, usage
}

/// Model management (D2 revised): one model per role — chat wants depth,
/// voice wants speed, background automation wants accuracy. Models load
/// on demand; an LRU eviction keeps combined RAM in budget.
struct ModelsSection: View {
    let pane: ModelsSetupPane

    @Environment(AppModel.self) private var model
    @State private var installed: [String] = MLXEngine.installedModels()
    @State private var assignments: [ModelTier: String] = currentAssignments()
    @State private var cloudSelections = currentCloudSelections()
    @State private var cloudUsage = CloudUsageSummary.empty
    @State private var cloudBreakdown: [String: CloudUsageBreakdown] = [:]
    @State private var cloudHistory: [String: [CloudUsageRecord]] = [:]
    @State private var localUsage = LocalModelUsageSummary.empty
    @State private var localBreakdown: [LocalModelUsageBreakdown] = []
    @State private var localHistory: [LocalModelUsageRecord] = []
    @State private var monthlyCallLimit = CloudAgentSettings.monthlyCallLimit
    @State private var nightlySettings = NightlyScheduleSettings.load()
    @State private var catalogExpanded = MLXEngine.installedModels().isEmpty

    struct CatalogEntry {
        let repo: String
        let revision: String
        let dir: String
        let size: String
        let hint: String
        let expectedBytes: Int64
    }

    /// Curated Qwen3 line-up — same family so templates/tool-calling stay
    /// consistent. Sizes are 4-bit MLX.
    static let catalog: [CatalogEntry] = [
        .init(repo: "mlx-community/Qwen3-1.7B-4bit",
              revision: "3b1b1768f8f8cf8351c712464f906e86c2b8269e",
              dir: "Qwen3-1.7B-4bit",
              size: "1.1 GB", hint: "fastest, simple replies", expectedBytes: 1_100_000_000),
        .init(repo: "mlx-community/Qwen3-4B-4bit",
              revision: "4dcb3d101c2a062e5c1d4bb173588c54ea6c4d25",
              dir: "Qwen3-4B-4bit",
              size: "2.2 GB", hint: "fast, good voice default", expectedBytes: 2_200_000_000),
        .init(repo: "mlx-community/Qwen3-8B-4bit",
              revision: "545dc4251c05440727734bcd94334791f6ab0192",
              dir: "Qwen3-8B-4bit",
              size: "4.6 GB", hint: "balanced", expectedBytes: 4_600_000_000),
        .init(repo: "mlx-community/Qwen3-14B-4bit",
              revision: "a4d9b2df59d2c150bef02fcbe0d91046b7ca33a4",
              dir: "Qwen3-14B-4bit",
              size: "8.2 GB", hint: "strong, still snappy", expectedBytes: 8_200_000_000),
        .init(repo: "mlx-community/Qwen3-30B-A3B-4bit",
              revision: "d388dead1515f5e085ef7a0431dd8fadf0886c57",
              dir: "Qwen3-30B-A3B-4bit",
              size: "17 GB", hint: "best quality (MoE, fast for its size)",
              expectedBytes: 17_000_000_000)
    ]

    @ViewBuilder
    var body: some View {
        switch pane {
        case .localModels:
            localModelsSection
        case .cloudAgents:
            cloudAgentsSection
        case .memory:
            memorySection
        case .usage:
            Group {
                cloudUsageSection
                    .onAppear { refreshUsage() }
                localUsageSection
            }
        }
    }

    private var localModelsSection: some View {
        Section("Local models") {
            if installed.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Download a model to get started", systemImage: "arrow.down.circle")
                        .font(.callout.weight(.semibold))
                    Text("Choose a model below, then assign it to Chat, Voice, or Background. Downloads stay on this Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(ModelTier.allCases, id: \.self) { role in
                Picker(roleLabel(role), selection: Binding(
                    get: { assignments[role] ?? MLXEngine.assignedModel(for: role) },
                    set: { newValue in
                        assignments[role] = newValue
                        MLXEngine.assign(model: newValue, to: role)
                    })) {
                    let assigned = assignments[role] ?? MLXEngine.assignedModel(for: role)
                    if !installed.contains(assigned) {
                        Text(installed.isEmpty
                             ? "Download a model first"
                             : "Unavailable: \(displayName(assigned))")
                            .tag(assigned)
                    }
                    ForEach(installed, id: \.self) { name in
                        Text(displayName(name)).tag(name)
                    }
                }
            }
            Text("Models load when needed; memory is managed automatically. Chat favors depth, Voice favors speed, and Background handles mail triage and automations.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            DisclosureGroup("Model downloads", isExpanded: $catalogExpanded) {
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
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green.opacity(0.7))
                            if !assignments.values.contains(entry.dir) {
                                Button("Delete") { delete(entry.dir) }
                                    .controlSize(.small)
                            }
                        } else {
                            if let status = model.modelDownloads.status[entry.dir] {
                                Text(status)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .frame(maxWidth: 260, alignment: .trailing)
                            }
                            if model.modelDownloads.activeModelID == entry.dir {
                                Button(model.modelDownloads.isCancelling ? "Pausing…" : "Pause") {
                                    model.modelDownloads.cancelActive()
                                }
                                .controlSize(.small)
                                .disabled(model.modelDownloads.isCancelling)
                            } else {
                                Button(model.modelDownloads.status[entry.dir] == nil
                                       ? "Download" : "Retry") {
                                    model.modelDownloads.start(
                                        repository: entry.repo,
                                        revision: entry.revision,
                                        modelID: entry.dir,
                                        expectedBytes: entry.expectedBytes)
                                }
                                .controlSize(.small)
                                .disabled(model.modelDownloads.activeModelID != nil)
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            installed = MLXEngine.installedModels()
            assignments = Self.currentAssignments()
            if installed.isEmpty { catalogExpanded = true }
        }
        .onChange(of: model.modelDownloads.completionRevision) {
            installed = MLXEngine.installedModels()
        }
        .onChange(of: installed) {
            if installed.isEmpty { catalogExpanded = true }
        }
    }

    private var cloudAgentsSection: some View {
        Section("Cloud agents") {
            VStack(alignment: .leading, spacing: 6) {
                Label("Choose cloud access separately for each feature.",
                      systemImage: "lock.shield")
                    .font(.callout.weight(.semibold))
                Text("These choices control AI-provider processing, not connected services. Usage records stay in your local profile and contain no prompt or response text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup("Advanced: cloud isolation policy") {
                Text("Every call receives Aitvaras Cloud Agent Policy v\(AitvarasCloudPolicy.version). Personal CLI skills, MCP servers, hooks and user configuration are disabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(CloudAgentFeature.allCases, id: \.self) { feature in
                VStack(alignment: .leading, spacing: 5) {
                    Picker(
                        feature.displayName,
                        selection: cloudBinding(for: feature)
                    ) {
                        ForEach(CloudModelSelection.allCases, id: \.self) {
                            Text($0 == .local
                                 ? feature.localMeaning : $0.displayName).tag($0)
                        }
                    }
                    let selection = cloudSelections[feature]
                        ?? CloudAgentSettings.defaultSelection(for: feature)
                    Text(selection == .local
                         ? "Local: no information for this feature is sent to a cloud model."
                         : feature.disclosure)
                        .font(.caption)
                        .foregroundStyle(selection == .local ? .tertiary : .secondary)
                    if selection != .local {
                        Text(feature.toolAccessDisclosure)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 3)
            }

            Text("Changes apply to the next call immediately. Enabling routine review also checks existing unreviewed candidates.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Divider()
            Stepper(
                monthlyCallLimit == 0
                    ? "Monthly cloud-call limit: unlimited"
                    : "Monthly cloud-call limit: \(monthlyCallLimit)",
                value: $monthlyCallLimit,
                in: 0...500,
                step: 10)
                .onChange(of: monthlyCallLimit) {
                    CloudAgentSettings.setMonthlyCallLimit(monthlyCallLimit)
                }
        }
        .onAppear {
            cloudSelections = Self.currentCloudSelections()
            monthlyCallLimit = CloudAgentSettings.monthlyCallLimit
        }
    }

    private var cloudUsageSection: some View {
        Section("Cloud usage") {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Cloud usage ledger · stored locally")
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Button("Refresh") { refreshUsage() }
                        .controlSize(.small)
                }
                Text("\(cloudUsage.callsToday) calls today · \(cloudUsage.callsThisMonth) this month · \(cloudUsage.successfulCallsThisMonth) successful")
                    .font(.caption)
                if let input = cloudUsage.inputTokensThisMonth,
                   let output = cloudUsage.outputTokensThisMonth {
                    Text("\(input.formatted()) input tokens · \(output.formatted()) output tokens reported this month")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Token totals appear when the selected CLI reports them.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if let cost = cloudUsage.reportedCostUSDThisMonth {
                    Text("Provider-reported API-equivalent cost: \(cost, format: .currency(code: "USD"))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let last = cloudUsage.lastUse {
                    Text("Last: \(last.feature) via \(last.provider), \(last.succeeded ? "succeeded" : "failed") · \(last.timestamp, style: .relative)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            ForEach(CloudAgentFeature.allCases, id: \.self) { feature in
                DisclosureGroup(feature.displayName) {
                    if let totals = cloudBreakdown[feature.rawValue] {
                        Text("\(totals.calls) calls · \(totals.successfulCalls) successful this month")
                            .font(.caption)
                        if let input = totals.inputTokens,
                           let output = totals.outputTokens {
                            Text("\(input.formatted()) input · \(output.formatted()) output tokens")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let cost = totals.reportedCostUSD {
                            Text("\(cost, format: .currency(code: "USD")) provider-reported API-equivalent cost")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("No calls recorded this month.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    let rows = cloudHistory[feature.rawValue] ?? []
                    ForEach(rows) { row in
                        HStack {
                            Image(systemName: row.succeeded
                                  ? "checkmark.circle" : "exclamationmark.circle")
                                .foregroundStyle(row.succeeded ? .green : .orange)
                            Text(row.provider == "claude"
                                 ? "Claude Code" : "Codex CLI")
                            Spacer()
                            if let input = row.inputTokens,
                               let output = row.outputTokens {
                                Text("\((input + output).formatted()) tokens")
                            }
                            Text("\(row.durationMilliseconds) ms")
                            Text(row.timestamp, style: .relative)
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var memorySection: some View {
        Section("Memory update schedule") {
            Picker("Schedule", selection: $nightlySettings.mode) {
                ForEach(NightlyScheduleMode.allCases, id: \.self) {
                    Text($0.displayName).tag($0)
                }
            }

            if nightlySettings.mode == .automatic {
                DatePicker(
                    "Earliest time",
                    selection: nightlyTimeBinding(\.earliestMinute),
                    displayedComponents: .hourAndMinute)
                Text("Recommended: Aitvaras treats this as a daily boundary. If the Mac is asleep, the update catches up after the next launch or wake.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if nightlySettings.mode == .fixedTime {
                DatePicker(
                    "Scheduled time",
                    selection: nightlyTimeBinding(\.fixedMinute),
                    displayedComponents: .hourAndMinute)
                Text("A sleeping Mac is not force-woken. A missed fixed time catches up after the next launch or wake.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if nightlySettings.mode != .off {
                Stepper(
                    "Delay after launch or wake: \(nightlySettings.wakeDelayMinutes) min",
                    value: $nightlySettings.wakeDelayMinutes,
                    in: 0...60,
                    step: 5)

                Picker("Run on battery", selection: $nightlySettings.powerPolicy) {
                    ForEach(NightlyPowerPolicy.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                if nightlySettings.powerPolicy == .batteryAboveThreshold {
                    Stepper(
                        "Minimum battery: \(nightlySettings.batteryThreshold)%",
                        value: $nightlySettings.batteryThreshold,
                        in: 5...100,
                        step: 5)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Label(
                        model.nightlyConsolidationRunning
                            ? "Updating memory"
                            : scheduleStateLabel(model.nightlyScheduleDecision.state),
                        systemImage: scheduleStateIcon(
                            model.nightlyScheduleDecision.state,
                            running: model.nightlyConsolidationRunning))
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Button("Run now") {
                        Task { await model.runNightlyConsolidationNow() }
                    }
                    .controlSize(.small)
                    .disabled(model.nightlyConsolidationRunning)
                }
                Text(model.nightlyScheduleDecision.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let last = model.nightlyLastSuccessfulRun {
                    Text("Last successful run: \(last.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Last successful run: never")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if let next = model.nightlyScheduleDecision.nextEligibleAt,
                   nightlySettings.mode != .off {
                    Text("Next eligible: \(next.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            let nightlyCloud = cloudSelections[.nightlyMemory]
                ?? CloudAgentSettings.defaultSelection(for: .nightlyMemory)
            Text(nightlyCloud == .local
                 ? "This update stays on this Mac. It runs unattended; any questions it discovers wait in Memory for you to answer later."
                 : "This unattended update sends archived conversation summaries and relevant current memory facts to \(nightlyCloud.displayName). Questions wait in Memory for you to answer later.")
                .font(.caption)
                .foregroundStyle(nightlyCloud == .local ? .tertiary : .secondary)
        }
        .onAppear {
            nightlySettings = .load()
            cloudSelections = Self.currentCloudSelections()
        }
        .onChange(of: nightlySettings) {
            model.updateNightlySchedule(nightlySettings)
        }
    }

    private var localUsageSection: some View {
        Section("On-device model usage") {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Local token credits").font(.callout.weight(.semibold))
                    Spacer()
                    Button("Refresh") { refreshUsage() }
                        .controlSize(.small)
                }
                Text("\(localUsage.tokenCreditsThisMonth.formatted()) token credits this month · \(localUsage.callsThisMonth) calls")
                    .font(.caption)
                Text("One token credit is one input or output token. Local credits have no monetary cost. Exact counts are used for MLX and Ollama; unsupported engines are clearly marked estimated.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(localBreakdown) { row in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("\(localEngineDisplayName(row.engine)) · \(row.tier.capitalized)")
                        Spacer()
                        Text("\(row.tokenCredits.formatted()) credits")
                    }
                    Text("\(row.calls) calls · \(row.inputTokens.formatted()) input · \(row.outputTokens.formatted()) output\(row.estimatedCalls > 0 ? " · \(row.estimatedCalls) estimated" : "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            DisclosureGroup("Recent local calls") {
                if localHistory.isEmpty {
                    Text("No local inference recorded yet.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                ForEach(localHistory) { row in
                    HStack {
                        Image(systemName: row.succeeded
                              ? "checkmark.circle" : "exclamationmark.circle")
                            .foregroundStyle(row.succeeded ? .green : .orange)
                        Text("\(localEngineDisplayName(row.engine)) · \(row.tier.capitalized)")
                        Spacer()
                        Text("\(row.tokenCredits.formatted())\(row.isEstimated ? " est." : "")")
                        Text(row.timestamp, style: .relative)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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

    private func nightlyTimeBinding(
        _ keyPath: WritableKeyPath<NightlyScheduleSettings, Int>
    ) -> Binding<Date> {
        Binding(
            get: {
                let minute = nightlySettings[keyPath: keyPath]
                return Calendar.current.date(
                    bySettingHour: minute / 60,
                    minute: minute % 60,
                    second: 0,
                    of: .now) ?? .now
            },
            set: { date in
                let components = Calendar.current.dateComponents(
                    [.hour, .minute], from: date)
                nightlySettings[keyPath: keyPath] =
                    (components.hour ?? 0) * 60 + (components.minute ?? 0)
            })
    }

    private func scheduleStateLabel(
        _ state: NightlyScheduleDecision.State
    ) -> String {
        switch state {
        case .disabled: "Automatic updates off"
        case .waiting: "Waiting"
        case .ready: "Ready"
        case .completed: "Up to date"
        }
    }

    private func scheduleStateIcon(
        _ state: NightlyScheduleDecision.State,
        running: Bool
    ) -> String {
        if running { return "moon.zzz.fill" }
        return switch state {
        case .disabled: "pause.circle"
        case .waiting: "clock"
        case .ready: "moon.zzz"
        case .completed: "checkmark.circle.fill"
        }
    }

    private func displayName(_ dir: String) -> String {
        dir.replacingOccurrences(of: "-4bit", with: "")
    }

    private func localEngineDisplayName(_ identifier: String) -> String {
        if identifier.hasPrefix("mlx:") {
            return "MLX · " + displayName(String(identifier.dropFirst(4)))
        }
        if identifier.hasPrefix("ollama:") {
            return "Ollama · " + String(identifier.dropFirst(7))
        }
        if identifier == "apple-fm" { return "Apple Foundation Models" }
        return displayName(identifier)
    }

    private static func currentAssignments() -> [ModelTier: String] {
        Dictionary(uniqueKeysWithValues: ModelTier.allCases.map { ($0, MLXEngine.assignedModel(for: $0)) })
    }

    private static func currentCloudSelections()
        -> [CloudAgentFeature: CloudModelSelection] {
        Dictionary(uniqueKeysWithValues: CloudAgentFeature.allCases.map {
            ($0, CloudAgentSettings.selection(for: $0))
        })
    }

    private func cloudBinding(
        for feature: CloudAgentFeature
    ) -> Binding<CloudModelSelection> {
        Binding(
            get: {
                cloudSelections[feature]
                    ?? CloudAgentSettings.defaultSelection(for: feature)
            },
            set: { value in
                cloudSelections[feature] = value
                model.setCloudAgentSelection(value, for: feature)
            })
    }

    private func refreshUsage() {
        guard let stores = model.stores else {
            cloudUsage = .empty
            cloudBreakdown = [:]
            cloudHistory = [:]
            localUsage = .empty
            localBreakdown = []
            localHistory = []
            return
        }
        cloudUsage = (try? stores.cloudUsageSummary()) ?? .empty
        cloudBreakdown = Dictionary(uniqueKeysWithValues:
            ((try? stores.cloudUsageBreakdown()) ?? []).map {
                ($0.feature, $0)
            })
        cloudHistory = Dictionary(uniqueKeysWithValues:
            CloudAgentFeature.allCases.map { feature in
                (feature.rawValue,
                 (try? stores.recentCloudUsage(
                    feature: feature.rawValue, limit: 8)) ?? [])
            })
        localUsage = (try? stores.localModelUsageSummary()) ?? .empty
        localBreakdown = (try? stores.localModelUsageBreakdown()) ?? []
        localHistory = (try? stores.recentLocalModelUsage(limit: 16)) ?? []
    }

    private func delete(_ dir: String) {
        do {
            try FileManager.default.removeItem(
                at: MLXEngine.modelsDirectory().appendingPathComponent(dir))
        } catch {
            model.presentError(title: "Model could not be deleted", error: error)
        }
        installed = MLXEngine.installedModels()
    }
}
