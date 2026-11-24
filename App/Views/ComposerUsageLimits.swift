import SwiftUI
import AitvarasAgents

struct ComposerUsageLimits: View {
    @AppReduceMotion private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var showsDetails = false
    let windows: [AgentRateLimitWindow]
    let narrow: Bool

    private struct Limit: Identifiable {
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
    }

    var body: some View {
        let limits = displayedLimits
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

    private var displayedLimits: [Limit] {
        let fiveHours = mostUsed(windows.filter { $0.duration == 5 * 3600 || $0.id == "five_hour" })
        let week = mostUsed(windows.filter { $0.duration == 7 * 86400 || $0.id == "seven_day" })
        var limits: [Limit] = []
        if let fiveHours {
            limits.append(Limit(id: "fiveHour", shortTitle: "5h", title: "Five-hour limit", window: fiveHours))
        }
        if let week {
            limits.append(Limit(id: "week", shortTitle: "Week", title: "Weekly limit", window: week))
        }
        if limits.isEmpty, let window = mostUsed(windows) {
            limits.append(Limit(id: "other", shortTitle: "Usage", title: "Usage limit", window: window))
        }
        return limits
    }

    private func mostUsed(_ candidates: [AgentRateLimitWindow]) -> AgentRateLimitWindow? {
        candidates.max {
            ($0.utilization.flatMap { $0.isFinite ? $0 : nil } ?? -1) <
                ($1.utilization.flatMap { $0.isFinite ? $0 : nil } ?? -1)
        }
    }

    private func indicator(_ limit: Limit, showsChevron: Bool) -> some View {
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

    private func details(_ limits: [Limit]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Usage limits").font(.headline).accessibilityAddTraits(.isHeader)
            ForEach(limits) { limit in
                if limit.id != limits.first?.id { Divider() }
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
                    if limit.id == "other", let duration = formattedDuration(limit.window.duration) {
                        Label(duration + " window", systemImage: "hourglass")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    resetRow(limit)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("chat.gauge.usage.\(limit.id)")
            }
        }
        .padding(16)
        .frame(width: 300)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.usage.popover")
    }

    private func resetRow(_ limit: Limit) -> some View {
        let date = limit.window.resetsAt
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "clock").foregroundStyle(.secondary)
                .accessibilityHidden(true)
            if let date {
                Text("Resets").foregroundStyle(.secondary)
                Text(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year()
                    .hour().minute().timeZone(.specificName(.short))))
            } else {
                Text("Reset time unavailable").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat.usage.reset.\(limit.id)")
    }

    private func formattedDuration(_ duration: TimeInterval?) -> String? {
        guard let duration, duration.isFinite, duration >= 60 else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .full
        return formatter.string(from: duration)
    }
}
