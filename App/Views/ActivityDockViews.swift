import SwiftUI
import AitvarasCore

/// Window-level activity chrome. Only its location is local state; all status
/// comes from the same presentation used by the menu bar and companion.
struct ActivityDockView: View {
    @Environment(AppModel.self) private var model
    @Binding var placement: ActivityDockPlacement
    let presentation: ActivityDockPlacement
    @State private var expanded = false
    private var status: ActivityPresentation { ActivityPresentation(model: model) }

    var body: some View {
        Group {
            if presentation == .sidebarFooter {
                sidebarFooter
            } else {
                horizontalDock
            }
        }
        .activityGlass(style: status.style, cornerRadius: presentation == .minimized ? 20 : 14)
        .accessibilityIdentifier("global-activity-\(presentation.rawValue)")
        .popover(isPresented: $expanded, arrowEdge: .bottom) {
            ActivityStatusPanel().environment(model)
        }
    }

    private var horizontalDock: some View {
        HStack(spacing: 10) {
            summaryButton {
                HStack(spacing: 10) {
                    statusIcon
                    VStack(alignment: .leading, spacing: 2) {
                        Text(status.title).font(.callout.weight(.semibold)).lineLimit(1)
                        if presentation == .bottomDock {
                            Text(status.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if presentation == .bottomDock {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) { operationCounts; attentionBadge }
                            attentionBadge
                        }
                    } else {
                        attentionBadge
                    }
                    Image(systemName: "chevron.up").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            placementMenu
        }
        .padding(.horizontal, 14)
        .frame(height: presentation == .minimized ? 40 : 54)
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                summaryButton {
                    HStack(spacing: 7) {
                        statusIcon
                        Text(status.title).font(.caption.weight(.semibold)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
                placementMenu
            }
            Text(status.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            if status.needsAttention {
                summaryButton { attentionBadge }
            } else if !status.roots.isEmpty || status.waiting > 0 {
                summaryButton { operationCounts }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusIcon: some View {
        Image(systemName: status.symbol)
            .font(.callout.weight(.semibold))
            .foregroundStyle(status.accent)
            .frame(width: 18)
            .accessibilityHidden(true)
    }

    private var operationCounts: some View {
        HStack(spacing: 8) {
            if !status.roots.isEmpty {
                Label("\(status.roots.count)", systemImage: "square.stack.3d.up")
            }
            if status.waiting > 0 {
                Label("\(status.waiting) waiting", systemImage: "clock")
            }
        }
        .font(.caption2).foregroundStyle(.secondary).fixedSize()
    }

    @ViewBuilder private var attentionBadge: some View {
        if status.needsAttention {
            let count = status.approvals + status.problems
            Label(count > 0 ? "\(count) attention" : "Attention", systemImage: "exclamationmark.triangle")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.86), in: Capsule())
                .fixedSize()
        }
    }

    private func summaryButton<Label: View>(@ViewBuilder label: () -> Label) -> some View {
        Button { expanded = true } label: {
            label().contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show activity details, approvals and automatic services")
        .accessibilityLabel(status.accessibilitySummary)
        .accessibilityHint("Opens activity details")
    }

    private var placementMenu: some View {
        Menu {
            Picker("Activity position", selection: $placement) {
                ForEach(ActivityDockPlacement.allCases) { location in
                    Text(location.title).tag(location)
                }
            }
            .pickerStyle(.inline)
            if placement == .sidebarFooter && presentation == .minimized {
                Text("Sidebar footer returns when the sidebar is shown.")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.callout.weight(.semibold))
                .frame(width: 24, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Activity position")
        .accessibilityLabel("Activity position")
    }
}
