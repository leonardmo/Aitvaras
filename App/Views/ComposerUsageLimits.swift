import AppKit
import SwiftUI
import AitvarasAgents

struct ComposerUsageLimits: View {
    @AppReduceMotion private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var showsDetails = false
    let windows: [AgentRateLimitWindow]
    let narrow: Bool
    var chat: ChatModel? = nil

    var body: some View {
        let limits = ProviderUsageLimit.displayed(windows)
        Button { showsDetails.toggle() } label: {
            HStack(spacing: 0) {
                ForEach(limits) { limit in
                    if limit.id != limits.first?.id {
                        Rectangle().fill(ink.opacity(0.24))
                            .frame(width: 1, height: 26).accessibilityHidden(true)
                    }
                    indicator(limit, showsChevron: limit.id == limits.last?.id)
                }
            }
            .clipShape(Capsule())
            .overlay { Capsule().strokeBorder(ink.opacity(contrast == .increased ? 0.52 : 0.20), lineWidth: 1) }
            .contentShape(Capsule())
            .fixedSize()
        }
        .buttonStyle(.plain)
        .help("Show usage and reset times")
        .accessibilityLabel("Usage limits")
        .accessibilityValue(limits.map { "\($0.title), \($0.status)" }.joined(separator: "; "))
        .accessibilityIdentifier("chat.usage.details")
        .popover(isPresented: $showsDetails, arrowEdge: .top) { details(limits) }
    }

    private var ink: Color { colorScheme == .dark ? Color(white: 0.94) : Color(white: 0.13) }

    private func indicator(_ limit: ProviderUsageLimit, showsChevron: Bool) -> some View {
        HStack(spacing: 3) {
            Text(limit.shortTitle).foregroundStyle(ink.opacity(0.8))
            Text(limit.percent.map { "\($0)%" } ?? "—").fontWeight(.semibold).monospacedDigit().foregroundStyle(ink)
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(ink.opacity(0.7))
                    .padding(.leading, 2)
            }
        }
        .font(.system(size: 10))
        .padding(.horizontal, narrow ? 6 : 9)
        .frame(height: 26)
        .background {
            if let used = limit.used {
                GradientTileSurface(ramp: .usage(used), cornerRadius: 0, prominent: true, outlined: false)
            } else {
                Rectangle().fill(Color.secondary.opacity(0.10))
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: limit.used)
    }

    private func details(_ limits: [ProviderUsageLimit]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(chat.map { "\($0.title($0.choice)) usage" } ?? "Usage limits")
                .font(.headline).accessibilityAddTraits(.isHeader)
            ForEach(limits) { limit in
                if limit.id != limits.first?.id { Divider() }
                ProviderUsageLimitRow(limit: limit)
                    .accessibilityIdentifier("chat.gauge.usage.\(limit.id)")
            }
            if let chat, let entry = chat.currentQuotaStop, let continuation = chat.autoContinueRow(entry) {
                Divider()
                AgentAutoContinueControls(row: continuation, identifier: "chat.usage.continuation",
                    updating: chat.isUpdatingAutoContinue(entry), error: chat.recoveryErrors[entry.id]) {
                        chat.setAutoContinue(entry, option: $0)
                    }
            }
            Divider()
            Button {
                showsDetails = false
                SettingsNavigation.open(.page(.usage), settingID: ProviderUsageSettings.settingID)
            } label: {
                HStack {
                    Label("Usage Settings", systemImage: "gearshape")
                    Spacer()
                    Image(systemName: "chevron.right").imageScale(.small).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.usage.settings")
        }
        .padding(16)
        .frame(width: 320)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.usage.popover")
    }
}

struct ProviderUsageSettings: View {
    static let settingID = "usage.providerLimits"

    let chat: ChatModel
    @State private var selectedChoice: AgentProviderChoice?

    var body: some View {
        let accounts = chat.allChoices.filter { $0.provider != .local }
        if let account = defaultChoice(in: accounts) {
            let selection = Binding(get: {
                selectedChoice.flatMap { accounts.contains($0) ? $0 : nil } ?? account
            }, set: { selectedChoice = $0 })
            let limits = ProviderUsageLimit.displayed(chat.profileLimits[selection.wrappedValue] ?? [])
            Section("Provider usage limits") {
                Picker("Account", selection: selection) {
                    ForEach(accounts) { choice in Text(chat.title(choice)).tag(choice) }
                }
                .settingsAnchor(Self.settingID)
                if limits.isEmpty {
                    Text("Usage and reset times are unavailable for this account.").foregroundStyle(.secondary)
                }
                ForEach(limits) { limit in
                    ProviderUsageLimitRow(limit: limit)
                        .accessibilityIdentifier("settings.usage.limit.\(limit.id)")
                        .id(selection.wrappedValue.id + "." + limit.id)
                }
            }
            .onChange(of: SettingsNavigation.shared.highlight) { _, highlight in
                if highlight?.settingID == Self.settingID { selectedChoice = nil }
            }
        }
    }

    private func defaultChoice(in accounts: [AgentProviderChoice]) -> AgentProviderChoice? {
        if accounts.contains(chat.choice) { return chat.choice }
        return accounts.first { chat.profileLimits[$0]?.isEmpty == false } ?? accounts.first
    }
}

private struct ProviderUsageLimit: Identifiable {
    let id: String
    let shortTitle: String
    let title: String
    let window: AgentRateLimitWindow

    var used: Double? {
        guard let value = window.utilization, value.isFinite else { return nil }
        return min(1, max(0, value))
    }
    var percent: Int? { used.map { Int(($0 * 100).rounded()) } }
    var status: String { percent.map { "\($0)% used" } ?? "Usage unavailable" }

    static func displayed(_ windows: [AgentRateLimitWindow]) -> [Self] {
        let fiveHours = mostUsed(windows.filter { $0.duration == 5 * 3600 || $0.id == "five_hour" })
        let week = mostUsed(windows.filter { $0.duration == 7 * 86400 || $0.id == "seven_day" })
        var limits: [Self] = []
        if let fiveHours {
            limits.append(Self(id: "fiveHour", shortTitle: "5h", title: "Five-hour limit", window: fiveHours))
        }
        if let week {
            limits.append(Self(id: "week", shortTitle: "Week", title: "Weekly limit", window: week))
        }
        if limits.isEmpty, let window = mostUsed(windows) {
            limits.append(Self(id: "other", shortTitle: "Usage", title: durationTitle(window.duration), window: window))
        }
        return limits
    }

    private static func durationTitle(_ duration: TimeInterval?) -> String {
        guard let duration, duration.isFinite, duration >= 60 else { return "Usage limit" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .full
        return formatter.string(from: duration).map { "\($0) limit" } ?? "Usage limit"
    }

    private static func mostUsed(_ candidates: [AgentRateLimitWindow]) -> AgentRateLimitWindow? {
        candidates.max {
            ($0.utilization.flatMap { $0.isFinite ? $0 : nil } ?? -1) <
                ($1.utilization.flatMap { $0.isFinite ? $0 : nil } ?? -1)
        }
    }
}

private struct ProviderUsageLimitRow: View {
    let limit: ProviderUsageLimit
    @State private var copiedDate: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(limit.title).font(.callout.weight(.medium))
                Spacer()
                Text(limit.status).font(.caption.weight(.medium)).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if let used = limit.used {
                GeometryReader { proxy in
                    Capsule().fill(.quaternary)
                        .overlay(alignment: .leading) {
                            Capsule().fill(ColorRamp.usage(used).wash(from: .leading, to: .trailing))
                                .frame(width: proxy.size.width * used)
                        }
                }
                .frame(height: 4)
                .accessibilityHidden(true)
            }
            HStack(spacing: 8) {
                if let date = limit.window.resetsAt {
                    let formatted = date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year()
                        .hour().minute().timeZone(.specificName(.short)))
                    Label {
                        Text("Resets \(formatted)")
                    } icon: {
                        Image(systemName: "clock").foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("usage.reset.\(limit.id)")
                    Spacer(minLength: 0)
                    Button {
                        NSPasteboard.general.clearContents()
                        if NSPasteboard.general.setString(formatted, forType: .string) { copiedDate = date }
                    } label: {
                        Image(systemName: copiedDate == date ? "checkmark" : "document.on.document")
                    }
                    .buttonStyle(.borderless)
                    .help(copiedDate == date ? "Reset time copied" : "Copy reset time")
                    .accessibilityLabel(copiedDate == date ? "Reset time copied for \(limit.title)" : "Copy reset time for \(limit.title)")
                    .accessibilityIdentifier("usage.copyReset.\(limit.id)")
                } else {
                    Label("Reset time unavailable", systemImage: "clock").foregroundStyle(.secondary)
                        .accessibilityIdentifier("usage.reset.\(limit.id)")
                }
            }
            .font(.caption)
        }
        .accessibilityElement(children: .contain)
    }
}
