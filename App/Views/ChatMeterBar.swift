import SwiftUI
import AitvarasAgent
import AitvarasStore

/// Context fill and local usage, shown where you type. Both are read from
/// what the app already records: the real per-turn history budget and the
/// stored usage counters. Nothing here calls a model or a provider.
struct ChatMeterBar: View {
    @Environment(AppModel.self) private var model
    @State private var local = LocalModelUsageSummary.empty
    @State private var cloud = CloudUsageSummary.empty
    @State private var detailShown = false

    private var usedCharacters: Int {
        AgentLoop.historyContextCharacters(for: model.messages.map(\.text))
    }
    private var budget: Int { max(1, AgentLoop.historyContextCharacterBudget) }
    private var fill: Double { min(1.2, Double(usedCharacters) / Double(budget)) }
    private var percent: Int { Int((fill * 100).rounded()) }

    private var meterColors: [Color] {
        switch fill {
        case ..<0.7: [ActivityGlassPalette.slate, ActivityGlassPalette.violet]
        case ..<0.95: [ActivityGlassPalette.violet, ActivityGlassPalette.ember]
        default: [ActivityGlassPalette.ember, ActivityGlassPalette.attention]
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Button { detailShown = true } label: {
                HStack(spacing: 8) {
                    meter
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Context \(percent)% · How much of this chat still fits in one turn")
            Button { detailShown = true } label: {
                Image(systemName: "bolt")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Usage details")
            .help(usageSummary)
        }
        .animation(.easeInOut(duration: 0.35), value: percent)
        .popover(isPresented: $detailShown, arrowEdge: .bottom) { detail }
        .task(id: model.messages.count) { await reload() }
    }

    private var meter: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(.quaternary).frame(width: 74, height: 5)
            Capsule()
                .fill(LinearGradient(colors: meterColors, startPoint: .leading, endPoint: .trailing))
                .frame(width: max(3, 74 * min(1, fill)), height: 5)
        }
        .accessibilityLabel("Context \(percent) percent full")
    }

    private var usageSummary: String {
        let replies = local.callsToday + cloud.callsToday
        let tokens = local.tokenCreditsThisMonth
            + (cloud.inputTokensThisMonth ?? 0) + (cloud.outputTokensThisMonth ?? 0)
        return "\(replies) today · \(Self.compact(tokens)) tokens this month"
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Context fill").font(.headline)
            Text("\(Self.compact(usedCharacters)) of \(Self.compact(budget)) characters of this chat fit in one turn. Older exchanges stop being sent once it is full; they stay saved here and are never deleted.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("Local usage").font(.headline)
            Text("\(local.callsToday) replies today · \(local.callsThisMonth) this month · \(Self.compact(local.tokenCreditsThisMonth)) tokens this month\(local.estimatedCallsThisMonth > 0 ? " (some counts estimated)" : "").")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if cloud.callsThisMonth > 0 {
                Text("Cloud usage: \(cloud.callsToday) today · \(cloud.callsThisMonth) this month. Cloud work stays separate from local chat.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16).frame(width: 330)
    }

    private func reload() async {
        guard let stores = model.stores else { return }
        local = (try? stores.localModelUsageSummary()) ?? .empty
        cloud = (try? stores.cloudUsageSummary()) ?? .empty
    }

    private static func compact(_ value: Int) -> String {
        value >= 1_000_000 ? String(format: "%.1fM", Double(value) / 1_000_000)
            : value >= 1_000 ? "\(value / 1_000)k" : "\(value)"
    }
}
