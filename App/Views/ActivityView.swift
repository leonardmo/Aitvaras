import SwiftUI
import Combine
import AitvarasCore
import AitvarasStore

/// Filter and page the durable database, not the bounded home snapshot.
struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @State private var roots: [ActivityRun] = []
    @State private var legacy: [ActivityEvent] = []
    @State private var serviceSummaries: [ServiceCheckSummary] = []
    @State private var checksExpanded = false
    @State private var summaryOffset = 0
    @State private var moreSummaries = false
    @State private var summaryError: String?
    @State private var search = ""
    @State private var category: ActivityCategory?
    @State private var state: ActivityRunState?
    @State private var period = "all"
    @State private var fromDate = Calendar.current.startOfDay(for: .now)
    @State private var throughDate = Date.now
    @State private var runOffset = 0
    @State private var legacyOffset = 0
    @State private var moreRuns = false
    @State private var moreLegacy = false
    @State private var loadingError: String?
    @State private var selectedRun: ActivityRun?
    @State private var selectedEvent: ActivityEvent?
    private let pageSize = 50

    var body: some View {
        VStack(spacing: 0) {
            filters
            Divider()
            List {
                if let loadingError {
                    Section { Label(loadingError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                }
                if roots.isEmpty && loadingError == nil {
                    Section {
                        Text(model.stores == nil ? "Starting; history is not available yet." : "No operations match these filters.").foregroundStyle(.secondary)
                    }
                }
                if !roots.isEmpty {
                    Text("Grouped by parent operation. Expanded groups include related work and recorded events.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(days, id: \.self) { day in
                    Section(day.formatted(date: .complete, time: .omitted)) {
                        ForEach(roots.filter { Calendar.current.startOfDay(for: $0.startedAt) == day }) { run in
                            RunHistoryGroup(run: run, selectedRun: $selectedRun, selectedEvent: $selectedEvent)
                        }
                    }
                }
                if moreRuns {
                    Section { Button("Load more operations") { loadRuns(reset: false) } }
                }
                backgroundChecksSection
                Section("Earlier activity · legacy entries") {
                    Text("These historical events predate operation tracking. Their completion state is not inferred.")
                        .font(.caption).foregroundStyle(.secondary)
                    if category != nil || state != nil {
                        Text("Clear category and state filters to include legacy entries, which do not have these fields.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(legacy) { event in
                            Button { selectedEvent = event } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(event.summary).font(.callout)
                                    Text(event.timestamp.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                        if legacy.isEmpty { Text("No matching legacy events.").font(.caption).foregroundStyle(.secondary) }
                        if moreLegacy { Button("Load more legacy events") { loadLegacy(reset: false) } }
                    }
                }
            }
        }
        .navigationTitle("History")
        .searchable(text: $search, prompt: "Search operations and earlier activity")
        .toolbar { Button("Refresh", systemImage: "arrow.clockwise") { reload() } }
        .task { reload() }
        .onChange(of: search) { reload() }
        .onChange(of: category) { reload() }
        .onChange(of: state) { reload() }
        .onChange(of: period) { reload() }
        .onChange(of: fromDate) { if period == "custom" { reload() } }
        .onChange(of: throughDate) { if period == "custom" { reload() } }
        .onChange(of: checksExpanded) { if checksExpanded { loadSummaries(reset: true) } }
        .onReceive(NotificationCenter.default.publisher(for: .aitvarasMonitoringChanged)
            .throttle(for: .milliseconds(400), scheduler: RunLoop.main, latest: true)) { _ in reload(preserveDepth: true) }
        .sheet(item: $selectedRun) { run in ActivityRunDetailView(run: run).environment(model) }
        .sheet(item: $selectedEvent) { event in ProvenanceSheet(event: event).environment(model) }
    }

    private var backgroundChecksSection: some View {
        Section {
            DisclosureGroup("Background checks", isExpanded: $checksExpanded) {
                Text("Daily service totals, not individual poll events. The selected date range applies; operation category, state and text filters do not.")
                    .font(.caption).foregroundStyle(.secondary)
                if let summaryError { Text(summaryError).font(.caption).foregroundStyle(.orange) }
                ForEach(serviceSummaries) { summary in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(summary.name).font(.callout.weight(.medium))
                            Spacer()
                            Text(summary.day).font(.caption).foregroundStyle(.secondary)
                        }
                        Text("\(summary.checks) checks · \(summary.successes) successful")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Last attempt: \(summary.lastAttempt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2).foregroundStyle(.secondary)
                        if let success = summary.lastSuccess {
                            Text("Last success: \(success.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 4)
                }
                if serviceSummaries.isEmpty && summaryError == nil {
                    Text("No background checks recorded in this date range.").font(.caption).foregroundStyle(.secondary)
                }
                if moreSummaries { Button("Load more daily summaries") { loadSummaries(reset: false) } }
            }
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Category", selection: $category) {
                    Text("All categories").tag(Optional<ActivityCategory>.none)
                    ForEach(ActivityCategory.allCases, id: \.self) { value in Text(value.rawValue.capitalized).tag(Optional(value)) }
                }
                Picker("State", selection: $state) {
                    Text("All states").tag(Optional<ActivityRunState>.none)
                    ForEach(ActivityRunState.allCases, id: \.self) { value in Text(value.monitoringTitle).tag(Optional(value)) }
                }
                Picker("Date", selection: $period) {
                    Text("All dates").tag("all")
                    Text("Today").tag("today")
                    Text("Last 7 days").tag("week")
                    Text("Last 30 days").tag("month")
                    Text("Date range").tag("custom")
                }
            }
            if period == "custom" {
                HStack {
                    DatePicker("From", selection: $fromDate, displayedComponents: .date)
                    DatePicker("Through", selection: $throughDate, in: fromDate..., displayedComponents: .date)
                }
            }
        }.padding(14)
    }
    private var days: [Date] { Array(Set(roots.map { Calendar.current.startOfDay(for: $0.startedAt) })).sorted(by: >) }
    private var since: Date? {
        switch period {
        case "today": Calendar.current.startOfDay(for: .now)
        case "week": Calendar.current.date(byAdding: .day, value: -7, to: .now)
        case "month": Calendar.current.date(byAdding: .day, value: -30, to: .now)
        case "custom": Calendar.current.startOfDay(for: fromDate)
        default: nil
        }
    }
    private var until: Date? {
        guard period == "custom" else { return nil }
        return Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: max(fromDate, throughDate)))?.addingTimeInterval(-0.001)
    }
    private func reload(preserveDepth: Bool = false) {
        loadingError = nil
        loadRuns(reset: true, limit: preserveDepth ? max(pageSize, runOffset) : pageSize)
        loadLegacy(reset: true, limit: preserveDepth ? max(pageSize, legacyOffset) : pageSize)
        if checksExpanded { loadSummaries(reset: true, limit: preserveDepth ? max(pageSize, summaryOffset) : pageSize) }
    }
    private func loadRuns(reset: Bool, limit: Int = 50) {
        guard let stores = model.stores else { return }
        do {
            let offset = reset ? 0 : runOffset
            let page = try stores.activityRuns(filter: ActivityRunFilter(category: category, state: state, search: search, since: since, until: until), limit: limit, offset: offset)
            var result = reset ? [] : roots
            for entry in page {
                var root = entry
                var visited: Set<UUID> = [entry.id]
                while let parentID = root.parentID, !visited.contains(parentID), visited.count < 64,
                      let parent = try stores.activityRun(id: parentID) {
                    root = parent
                    visited.insert(parentID)
                }
                if let index = result.firstIndex(where: { $0.id == root.id }) { result[index] = root }
                else { result.append(root) }
            }
            roots = result.sorted { $0.startedAt > $1.startedAt }
            runOffset = offset + page.count
            moreRuns = page.count == limit
        } catch { loadingError = "History could not be loaded. Previously loaded entries may be stale." }
    }
    private func loadLegacy(reset: Bool, limit: Int = 50) {
        guard let stores = model.stores else { return }
        do {
            let offset = reset ? 0 : legacyOffset
            let page = try stores.legacyActivity(limit: limit, offset: offset, search: search, since: since, until: until)
            legacy = reset ? page : legacy + page
            legacyOffset = offset + page.count
            moreLegacy = page.count == limit
        } catch { loadingError = "Earlier activity could not be loaded. Previously loaded entries may be stale." }
    }
    private func loadSummaries(reset: Bool, limit: Int = 50) {
        guard let stores = model.stores else { return }
        do {
            let offset = reset ? 0 : summaryOffset
            let page = try stores.serviceCheckSummaries(limit: limit, offset: offset, since: since, until: until)
            serviceSummaries = reset ? page : serviceSummaries + page
            summaryOffset = offset + page.count
            moreSummaries = page.count == limit
            summaryError = nil
        } catch { summaryError = "Background check summaries could not be loaded. Previously loaded totals may be stale." }
    }
}

private struct RunHistoryGroup: View {
    @Environment(AppModel.self) private var model
    let run: ActivityRun
    @Binding var selectedRun: ActivityRun?
    @Binding var selectedEvent: ActivityEvent?
    @State private var expanded = false
    @State private var children: [ActivityRun] = []
    @State private var events: [ActivityEvent] = []
    @State private var steps: [ActivityRunStep] = []
    @State private var error: String?
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Button("Operation details…") { selectedRun = run }.controlSize(.small)
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            ForEach(steps) { step in
                Label(step.stage, systemImage: step.state.monitoringIcon)
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(children) { child in
                Button { selectedRun = child } label: { ActivityRunRow(run: child) }.buttonStyle(.plain)
            }
            ForEach(events) { event in
                Button { selectedEvent = event } label: {
                    Label(event.summary, systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
            }
            if children.isEmpty && events.isEmpty && steps.isEmpty && error == nil { Text("No child events recorded.").font(.caption).foregroundStyle(.secondary) }
        } label: { ActivityRunRow(run: run) }
        .onChange(of: expanded) { if expanded { loadChildren() } }
        .task {
            if AitvarasPaths.isIsolated,
               ProcessInfo.processInfo.environment["AITVARAS_UI_TEST_MODE"] == "1",
               CommandLine.arguments.contains("--expand-history-fixture") { expanded = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .aitvarasMonitoringChanged)) { _ in
            if expanded { loadChildren() }
        }
    }
    private func loadChildren() {
        do {
            children = try model.stores?.activityChildRuns(parentID: run.id) ?? []
            events = try model.stores?.activityEvents(runID: run.id) ?? []
            steps = try model.stores?.activityRunSteps(runID: run.id) ?? []
        } catch { self.error = "Child operations and events could not be loaded." }
    }
}

/// Legacy provenance remains available, with raw payloads opt-in only.
struct ProvenanceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let event: ActivityEvent
    @State private var chain: [ActivityEvent] = []
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Event provenance").font(.title3.weight(.semibold))
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.escape)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let error { Text(error).foregroundStyle(.orange) }
                    ForEach(chain) { step in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(step.summary).font(.callout)
                            Text(step.timestamp.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.secondary)
                            if let connector = step.connectorID { Text("Source: \(connector)").font(.caption).foregroundStyle(.secondary) }
                            if let detail = step.detailJSON, !detail.isEmpty {
                                DisclosureGroup("Technical details") { Text(detail).font(.caption.monospaced()).textSelection(.enabled) }
                            }
                        }
                        Divider()
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(24).frame(width: 560, height: 500)
        .task {
            do { chain = try model.stores?.provenance(of: event.id) ?? [event] }
            catch { chain = [event]; self.error = "The full provenance chain could not be loaded." }
        }
    }
}
