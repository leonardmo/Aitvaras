import SwiftUI
import AitvarasCore
import AitvarasStore

/// The audit trail (D13): everything Aitvaras did, and why.
struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @State private var selected: ActivityEvent?

    var body: some View {
        List(model.activity, id: \.id) { event in
            Button {
                selected = event
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon(for: event.kind))
                        .foregroundStyle(color(for: event.kind))
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.summary)
                            .lineLimit(2)
                        HStack(spacing: 6) {
                            if let connector = event.connectorID {
                                Text(connector)
                                    .font(.caption2.monospaced())
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(.quaternary))
                            }
                            Text(event.timestamp, style: .relative)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .overlay {
            if model.activity.isEmpty {
                ContentUnavailableView(
                    "Nothing yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Every action Aitvaras takes shows up here, with the chain of causes behind it."))
            }
        }
        .navigationTitle("Activity")
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") { model.refreshSidebandData() }
        }
        .sheet(item: $selected) { event in
            ProvenanceSheet(event: event)
                .environment(model)
        }
    }

    private func icon(for kind: ActivityEvent.Kind) -> String {
        switch kind {
        case .eventReceived: "tray.and.arrow.down"
        case .classification: "sparkles"
        case .toolExecuted: "gearshape"
        case .suggestionOffered: "questionmark.bubble"
        case .suggestionAccepted: "checkmark.circle"
        case .suggestionRejected: "xmark.circle"
        case .confirmationDenied: "hand.raised"
        case .notificationSent: "paperplane"
        case .delegationRun: "terminal"
        case .voiceTurn: "waveform"
        case .conversationArchived: "archivebox"
        case .consolidationRun: "moon.zzz"
        case .captureFinished: "record.circle"
        }
    }

    private func color(for kind: ActivityEvent.Kind) -> Color {
        switch kind {
        case .eventReceived: .blue
        case .classification: .purple
        case .toolExecuted: .primary
        case .suggestionOffered: .orange
        case .suggestionAccepted: .green
        case .suggestionRejected, .confirmationDenied: .red
        case .notificationSent: .teal
        case .delegationRun: .indigo
        case .voiceTurn: .mint
        case .conversationArchived: .brown
        case .consolidationRun: .purple
        case .captureFinished: .red
        }
    }
}

/// "What happened, because of what" — walks the causedBy chain (D13).
struct ProvenanceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let event: ActivityEvent
    @State private var chain: [ActivityEvent] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Provenance")
                .font(.title3.weight(.semibold))
            if chain.isEmpty {
                ProgressView()
            } else {
                ForEach(Array(chain.enumerated()), id: \.element.id) { index, step in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(spacing: 0) {
                            Circle().fill(index == 0 ? Color.accentColor : .secondary)
                                .frame(width: 8, height: 8)
                            if index < chain.count - 1 {
                                Rectangle().fill(.quaternary).frame(width: 1, height: 28)
                            }
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.summary)
                            Text(step.timestamp.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            if let detail = step.detailJSON, !detail.isEmpty {
                                Text(detail)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(4)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.escape)
        }
        .padding(24)
        .frame(width: 460, height: 420)
        .task {
            chain = (try? model.stores?.provenance(of: event.id)) ?? [event]
        }
    }
}
