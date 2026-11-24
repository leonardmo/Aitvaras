import SwiftUI
import AitvarasAgents

struct ComposerUsageLimits: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    let windows: [AgentRateLimitWindow]
    let narrow: Bool

    var body: some View {
        let fiveHours = mostUsed(windows.filter { $0.duration == 5 * 3600 || $0.id == "five_hour" })
        let week = mostUsed(windows.filter { $0.duration == 7 * 86400 || $0.id == "seven_day" })
        HStack(spacing: narrow ? 3 : 5) {
            if let fiveHours {
                indicator(fiveHours, title: "5h", label: "Five-hour limit", identifier: "fiveHour")
            }
            if let week {
                indicator(week, title: "Week", label: "Weekly limit", identifier: "week")
            }
            if fiveHours == nil, week == nil, let window = mostUsed(windows) {
                indicator(window, title: "Usage", label: "Usage limit", identifier: "other")
            }
        }
        .fixedSize()
    }

    private func mostUsed(_ candidates: [AgentRateLimitWindow]) -> AgentRateLimitWindow? {
        candidates.max { (fraction($0) ?? -1) < (fraction($1) ?? -1) }
    }

    private func fraction(_ window: AgentRateLimitWindow) -> Double? {
        guard let value = window.utilization, value.isFinite else { return nil }
        return min(1, max(0, value))
    }

    private func indicator(_ window: AgentRateLimitWindow, title: String, label: String, identifier: String) -> some View {
        let used = fraction(window)
        let percent = used.map { "\(Int(($0 * 100).rounded()))%" }
        let status = percent.map { "\($0) used" } ?? "Usage unavailable"
        let reset = window.resetsAt.map { " · Resets \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
        let ink = colorScheme == .dark ? Color(white: 0.94) : Color(white: 0.13)
        return HStack(spacing: 3) {
            Text(title).foregroundStyle(ink.opacity(0.8))
            Text(percent ?? "—").fontWeight(.semibold).monospacedDigit().foregroundStyle(ink)
        }
        .font(.system(size: 10))
        .padding(.horizontal, narrow ? 4 : 6)
        .frame(height: 22)
        .background {
            if let used {
                GradientTileSurface(ramp: .usage(used), cornerRadius: 7, prominent: true)
            } else {
                RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.10))
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: used)
        .help("\(label) · \(status)\(reset)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(status)\(reset)")
        .accessibilityIdentifier("chat.gauge.usage.\(identifier)")
    }

}
