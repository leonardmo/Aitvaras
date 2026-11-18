import SwiftUI
import AitvarasCore
import AitvarasStore
import AitvarasAgents

/// A read-first home: attention, current work, services, results, then goals.
struct TodayView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem
    @State private var selectedRun: ActivityRun?
    @State private var reviewAutomaticWork = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(greeting).font(.largeTitle.weight(.semibold))
                    Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day())).font(.callout).foregroundStyle(.secondary)
                }
                attentionCard
                nowCard
                servicesCard
                resultsCard
                if let snapshot = model.todaySnapshot, !snapshot.goals.isEmpty { goalsCard(snapshot) }
            }
            .frame(maxWidth: 880, alignment: .leading).padding(24).frame(maxWidth: .infinity)
        }
        .navigationTitle("Home")
        .toolbar { Button("Refresh", systemImage: "arrow.clockwise") { model.refreshSidebandData(); model.refreshMonitoring() } }
        .sheet(item: $selectedRun) { run in ActivityRunDetailView(run: run).environment(model) }
        .sheet(isPresented: $reviewAutomaticWork) {
            VStack(spacing: 0) {
                HStack { Spacer(); Button("Close") { reviewAutomaticWork = false }.keyboardShortcut(.escape) }.padding()
                BackgroundReviewView().environment(model)
            }.frame(width: 650, height: 650)
        }
    }

    private var attentionCard: some View {
        let card = model.attentionCard
        return HomeCard(title: "Needs your attention", icon: "hand.raised", tint: .orange,
                        actionTitle: card.canDismissAll ? "Dismiss all" : nil,
                        actionIdentifier: "home.attention.dismissAll", action: { AttentionActions.dismissAll(model: model) }) {
            AttentionRowsView(rows: card.visibleRows, selection: $selection)
            if card.overflowCount > 0 {
                Button("\(card.overflowCount) more", systemImage: "arrow.right") {
                    model.historyAttentionRequested = true
                    selection = .activity
                }
                    .font(.callout).buttonStyle(.plain).foregroundStyle(Color.accentColor)
                    .accessibilityLabel("\(card.overflowCount) more attention items in History")
                    .accessibilityIdentifier("home.attention.more")
            }
            if card.rows.isEmpty {
                Text(model.homeAttentionSnapshot == nil
                     ? "Starting; attention items are not available yet."
                     : "Nothing needs your attention right now.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            AttentionUndoBar()
        }
        .accessibilityIdentifier("home.attention.card")
    }

    private var nowCard: some View {
        HomeCard(title: "Now", icon: "waveform.path") {
            if !model.monitoringReady {
                Label("Starting activity monitoring…", systemImage: "clock").foregroundStyle(.secondary)
            } else if model.monitoringError != nil {
                Text("Current work cannot be confirmed. The last saved status may be stale.").foregroundStyle(.orange)
            } else if model.currentActivityRuns.isEmpty {
                Text("No operations are currently running.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.topLevelCurrentActivity) { run in
                Button { selectedRun = run } label: { ActivityRunRow(run: run) }.buttonStyle(.plain)
            }
        }
    }

    private var servicesCard: some View {
        HomeCard(title: "Automatic services", icon: "clock.badge.checkmark") {
            if !model.backgroundPolicy.reviewed {
                Text("Not reviewed · all automatic features are off.").font(.callout).foregroundStyle(.secondary)
            } else if model.backgroundPolicy.paused {
                Text("Automatic work is paused. Your saved feature choices are preserved.").font(.callout).foregroundStyle(.secondary)
            }
            if model.monitoredServices.filter(\.enabled).isEmpty {
                Text(model.monitoringReady ? "No automatic services enabled." : "Service status is not available yet.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.monitoredServices.filter(\.enabled)) { service in ServiceStatusRow(service: service) }
            Button("Review automatic work…") { reviewAutomaticWork = true }
        }
    }

    private var resultsCard: some View {
        HomeCard(title: "Recent results", icon: "checklist") {
            if recentResults.isEmpty {
                Text(model.monitoringReady ? "No completed operations recorded yet." : "Results are not available yet.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(recentResults.prefix(5)) { run in
                Button { selectedRun = run } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        ActivityRunRow(run: run)
                        if let outcome = run.outcome { Text(outcome).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    }
                }.buttonStyle(.plain)
            }
            Button("Open History") { selection = .activity }
        }
    }

    private func goalsCard(_ snapshot: TodaySnapshot) -> some View {
        HomeCard(title: "Today's goals", icon: "checkmark.circle") {
            ForEach(snapshot.goals) { goal in
                Button {
                    do {
                        if try model.stores?.setGoalDone(goal.id, done: !goal.done) == true { model.refreshSidebandData() }
                    } catch { model.presentError(title: "Goal could not be updated", error: error) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: goal.done ? "checkmark.circle.fill" : "circle").foregroundStyle(goal.done ? Color.green : .secondary)
                        Text(goal.text).strikethrough(goal.done).foregroundStyle(goal.done ? .secondary : .primary)
                        Spacer()
                    }.padding(.vertical, 6).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }
    private var recentResults: [ActivityRun] { model.recentActivityRuns.filter { $0.state.isTerminal && $0.parentID == nil } }
    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
    }
}

/// The same decision, dismissal and navigation controls on Home and History.
struct AttentionRowsView: View {
    @Environment(AppModel.self) private var model
    let rows: [HomeAttentionRow]
    @Binding var selection: SidebarItem
    @State private var selectedDetail: ActivityRunDetailSelection?
    @State private var selectedHeldUpdate: HeldNotification?
    @State private var reviewAutomaticWork = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(rows) { row in
                attentionRow(row)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(row.accessibilityIdentifier)
            }
        }
        .sheet(item: $selectedDetail) { selection in
            ActivityRunDetailView(run: selection.run, group: selection.group).environment(model)
        }
        .sheet(item: $selectedHeldUpdate) { item in
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(item.title).font(.headline)
                    Spacer()
                    Button("Close") { selectedHeldUpdate = nil }.keyboardShortcut(.escape)
                }
                ScrollView { Text(item.body).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
            }
            .padding(24).frame(minWidth: 360, idealWidth: 440, maxWidth: 600, minHeight: 180, idealHeight: 280, maxHeight: 500)
        }
        .sheet(isPresented: $reviewAutomaticWork) {
            VStack(spacing: 0) {
                HStack { Spacer(); Button("Close") { reviewAutomaticWork = false }.keyboardShortcut(.escape) }.padding()
                BackgroundReviewView().environment(model)
            }.frame(width: 650, height: 650)
        }
    }

    @ViewBuilder private func attentionRow(_ row: HomeAttentionRow) -> some View {
        switch row {
        case .approval(let suggestion):
            if let chat = model.chatModel { HomeAgentApprovalRow(suggestion: suggestion, chat: chat) }
        case .suggestion(let suggestion):
            VStack(alignment: .leading, spacing: 6) {
                HomeAttentionSummary(title: suggestion.title, detail: suggestion.detail, icon: "hand.raised", tint: .accentColor)
                HStack {
                    Spacer()
                    Button("Reject") { model.reject(suggestion) }
                        .accessibilityIdentifier(row.accessibilityIdentifier + ".reject")
                    Button("Approve") { model.accept(suggestion) }.buttonStyle(.borderedProminent)
                        .accessibilityIdentifier(row.accessibilityIdentifier + ".approve")
                }.controlSize(.small).disabled(model.hub == nil)
            }
        case .unsavedCapture(let run):
            VStack(alignment: .leading, spacing: 6) {
                HomeAttentionSummary(title: run.title, detail: "Capture needs to be saved", icon: "record.circle", tint: .orange)
                HStack {
                    Spacer()
                    Button("Open") { selection = .capture }
                        .accessibilityIdentifier(row.accessibilityIdentifier + ".open")
                    Button("Save") { if canSaveCapture(run) { model.toggleCapture() } }
                        .disabled(!canSaveCapture(run))
                        .accessibilityIdentifier(row.accessibilityIdentifier + ".save")
                }.controlSize(.small)
            }
        case .problem(let group):
            HStack(alignment: .center, spacing: 8) {
                Button { selectedDetail = ActivityRunDetailSelection(group: group) } label: {
                    HomeAttentionSummary(title: group.latestRun.title, detail: group.latestRun.outcome,
                        icon: group.latestRun.state.monitoringIcon, tint: .orange,
                        count: group.totalCount > 1 ? group.totalCount : nil)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open details: \(group.latestRun.title)")
                .accessibilityValue("\(group.latestRun.state.monitoringTitle), \(group.totalCount) occurrences")
                .accessibilityIdentifier(row.accessibilityIdentifier + ".open")
                HomeAttentionDismissButton(row: row) { AttentionActions.dismiss(row, model: model) }
            }
        case .monitoring(let incident):
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    HomeAttentionSummary(title: row.title, detail: incident.message, icon: "exclamationmark.shield", tint: .orange)
                    if model.stores == nil || model.recentActivityRuns.contains(where: { $0.category == .startup && $0.state == .failed }) {
                        Button("Retry startup") { Task { await model.bootstrapIfNeeded() } }
                            .controlSize(.small)
                            .accessibilityIdentifier(row.accessibilityIdentifier + ".retryStartup")
                    }
                }
                HomeAttentionDismissButton(row: row) { AttentionActions.dismiss(row, model: model) }
            }
        case .heldUpdate(let item):
            HStack(alignment: .center, spacing: 8) {
                Button { selectedHeldUpdate = item } label: {
                    HomeAttentionSummary(title: item.title, detail: item.body, icon: "tray", tint: .accentColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open update: \(item.title)")
                .accessibilityIdentifier(row.accessibilityIdentifier + ".open")
                HomeAttentionDismissButton(row: row) { AttentionActions.dismiss(row, model: model) }
            }
        case .automaticWork:
            HStack(alignment: .center, spacing: 8) {
                Button { reviewAutomaticWork = true } label: {
                    HomeAttentionSummary(title: row.title,
                        detail: "Choose which automatic features may run. They remain off until you save your choices.",
                        icon: "clock.badge.checkmark", tint: .accentColor)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(row.accessibilityIdentifier + ".open")
                HomeAttentionDismissButton(row: row) { AttentionActions.dismiss(row, model: model) }
            }
        }
    }

    private func canSaveCapture(_ run: ActivityRun) -> Bool {
        guard let capture = model.capture else { return false }
        return capture.activityRunID == run.id && capture.canFinish
            && !capture.isActive && !capture.isStarting && !capture.isFinishing
    }
}

struct AttentionUndoBar: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if let receipt = model.attentionDismissals.receipt, model.attentionDismissals.canUndo {
            HStack(spacing: 5) {
                Text("Dismissed \(receipt.itemCount) \(receipt.itemCount == 1 ? "item" : "items") ·")
                    .foregroundStyle(.secondary)
                Button("Undo", action: { AttentionActions.undo(model: model) })
                    .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                    .keyboardShortcut("z", modifiers: .command)
                    .accessibilityIdentifier("home.attention.undo")
                Spacer()
            }
            .font(.callout).padding(.top, 4)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("home.attention.undoBar")
        }
    }
}

@MainActor enum AttentionActions {
    static func dismissAll(model: AppModel) {
        performDismissal(model: model) { try $0.dismissAllAttention() }
    }

    static func dismiss(_ row: HomeAttentionRow, model: AppModel) {
        switch row {
        case .problem(let group):
            performDismissal(model: model) {
                if group.latestRun.state == .outcomeUnknown {
                    return try $0.dismissUnknownOutcome(id: group.latestRun.id)
                }
                return try $0.dismissAttentionProblemGroup(group)
            }
        case .heldUpdate(let item): performDismissal(model: model) { try $0.dismissHeldUpdates(ids: [item.id]) }
        case .automaticWork: performDismissal(model: model) { try $0.deferAutomaticWorkPrompt() }
        case .monitoring(let incident):
            guard let stores = model.stores, model.attentionDismissals.monitoringIncidentID == incident.id else { return }
            do { _ = try model.attentionDismissals.hideMonitoringIncident(using: stores) }
            catch { model.presentError(title: "Warning could not be hidden", error: error) }
        default: break // Approvals and at-risk captures never enter dismissal.
        }
    }

    private static func performDismissal(model: AppModel, _ action: (Stores) throws -> AttentionDismissalReceipt) {
        guard let stores = model.stores else { return }
        do {
            model.attentionDismissals.present(try action(stores))
            model.refreshSidebandData()
        } catch { model.presentError(title: "Attention could not be dismissed", error: error) }
    }

    static func undo(model: AppModel) {
        guard let stores = model.stores else { return }
        do {
            if let result = try model.attentionDismissals.undo(using: stores),
               !result.runIDs.isEmpty || !result.heldUpdateIDs.isEmpty || result.restoredPrompt {
                model.refreshSidebandData()
            }
        } catch { model.presentError(title: "Dismissal could not be undone", error: error) }
    }
}

private struct HomeAttentionSummary: View {
    let title: String
    var detail: String? = nil
    let icon: String
    let tint: Color
    var count: Int? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 18).padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.callout.weight(.medium)).lineLimit(1)
                    if let count {
                        Text("×\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .accessibilityLabel("\(count) occurrences")
                    }
                }
                if let detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
}

/// Always present, with native keyboard/VoiceOver button semantics. Hover and
/// focus increase emphasis rather than exposing an otherwise hidden control.
private struct HomeAttentionDismissButton: View {
    let row: HomeAttentionRow
    let action: () -> Void
    @State private var hovered = false
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            Group {
                if row.dismissal == .later { Text("Later") }
                else { Image(systemName: "xmark") }
            }
            .font(.caption.weight(.medium))
            .frame(width: row.dismissal == .later ? 44 : 24, height: 24)
            .contentShape(Rectangle())
            .background(hovered || focused ? Color.primary.opacity(0.08) : .clear,
                        in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .foregroundStyle(hovered || focused ? Color.primary : .secondary)
        .focusable()
        .focused($focused)
        .onHover { hovered = $0 }
        .help(row.dismissalAccessibilityLabel ?? "")
        .accessibilityLabel(row.dismissalAccessibilityLabel ?? "")
        .accessibilityIdentifier(row.accessibilityIdentifier + ".dismiss")
    }
}

private struct HomeAgentApprovalRow: View {
    let suggestion: AgentApprovalSuggestion
    let chat: ChatModel
    @State private var responding = false
    @State private var failed = false

    var body: some View {
        let row = HomeAttentionRow.approval(suggestion)
        VStack(alignment: .leading, spacing: 6) {
            HomeAttentionSummary(title: row.title, detail: suggestion.request.presentation.detail,
                                 icon: "hand.raised", tint: .accentColor)
            HStack {
                Text(chat.approvalContext(suggestion)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if responding { ProgressView().controlSize(.mini) }
                Button("Reject") { answer(.deny) }
                    .accessibilityIdentifier(row.accessibilityIdentifier + ".reject")
                Button("Approve") { answer(.allow(updatedInput: nil)) }.buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(row.accessibilityIdentifier + ".approve")
            }.controlSize(.small).disabled(responding || failed)
            if failed { Text("This request is no longer available.").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func answer(_ response: AgentResponse) {
        guard !responding, !failed else { return }
        responding = true
        Task {
            failed = !(await chat.respond(chatID: suggestion.chatID, to: suggestion.request, with: response))
            responding = false
        }
    }
}

private struct HomeCard<Content: View>: View {
    let title: String
    let icon: String
    var tint: Color = .accentColor
    var actionTitle: String? = nil
    var actionIdentifier = ""
    var action: () -> Void = {}
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(title, systemImage: icon).font(.headline).foregroundStyle(tint)
                Spacer()
                if let actionTitle {
                    Button(actionTitle, action: action).controlSize(.small)
                        .accessibilityIdentifier(actionIdentifier)
                }
            }
            content
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary) }
    }
}
