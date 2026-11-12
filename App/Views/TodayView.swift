import SwiftUI
import AitvarasCore
import AitvarasStore

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
        HomeCard(title: "Needs your attention", icon: "hand.raised", tint: .orange) {
            if let chat = model.chatModel { AgentApprovalSuggestionsView(chat: chat) }
            if let snapshot = model.todaySnapshot {
                ForEach(snapshot.pendingSuggestions) { suggestion in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(suggestion.title).font(.callout.weight(.medium))
                        if !suggestion.detail.isEmpty { Text(suggestion.detail).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                        HStack {
                            Text("\(suggestion.connectorID) · \(suggestion.toolName)").font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Button("Dismiss") { model.reject(suggestion) }.controlSize(.small)
                            Button("Approve") { model.accept(suggestion) }.buttonStyle(.borderedProminent).controlSize(.small)
                        }
                    }
                    Divider()
                }
                if snapshot.pendingSuggestionCount > snapshot.pendingSuggestions.count {
                    Text("More suggestions are waiting in Chat.").font(.caption).foregroundStyle(.secondary)
                    Button("Open Chat") { selection = .chat }
                }
                if !snapshot.heldNotifications.isEmpty {
                    Label("Updates available", systemImage: "tray").font(.caption).foregroundStyle(.secondary)
                    ForEach(snapshot.heldNotifications) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).font(.callout)
                            Text(item.body).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
            ForEach(attentionRuns.prefix(4)) { run in
                Button { selectedRun = run } label: { ActivityRunRow(run: run) }.buttonStyle(.plain)
            }
            if attentionRuns.count > 4 { Button("Review more attention items in History") { selection = .activity } }
            if let error = model.monitoringError {
                Text(error).font(.callout).foregroundStyle(.orange)
                if model.stores == nil || model.recentActivityRuns.contains(where: { $0.category == .startup && $0.state == .failed }) {
                    Button("Retry startup") { Task { await model.bootstrapIfNeeded() } }
                }
            }
            if !model.backgroundPolicy.reviewed {
                Text("Choose which automatic features may run. They remain off until you save your choices.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Review automatic work…") { reviewAutomaticWork = true }
            } else if attentionRuns.isEmpty && model.monitoringError == nil,
                      let snapshot = model.todaySnapshot,
                      snapshot.pendingSuggestionCount == 0 && snapshot.heldNotificationCount == 0 && model.chatModel?.approvalSuggestions.isEmpty != false {
                Text("Nothing needs your attention right now.").font(.callout).foregroundStyle(.secondary)
            } else if model.todaySnapshot == nil && model.stores == nil {
                Text("Starting; attention items are not available yet.").font(.callout).foregroundStyle(.secondary)
            }
        }
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
    private var attentionRuns: [ActivityRun] {
        model.recentActivityRuns.filter {
            ([.failed, .interrupted, .outcomeUnknown, .awaitingApproval].contains($0.state)
                || ($0.category == .capture && $0.state == .waiting))
                && $0.acknowledgedAt == nil
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

private struct HomeCard<Content: View>: View {
    let title: String
    let icon: String
    var tint: Color = .accentColor
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon).font(.headline).foregroundStyle(tint)
            content
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary) }
    }
}
