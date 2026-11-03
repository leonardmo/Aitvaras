import SwiftUI
import AitvarasCore
import AitvarasStore
import AitvarasConnectors

enum ActivityGlassPalette {
    static let ember = Color(red: 0.91, green: 0.38, blue: 0.21)
    static let slate = Color(red: 0.30, green: 0.49, blue: 0.76)
    static let violet = Color(red: 0.60, green: 0.40, blue: 0.78)
    static let attention = Color.orange
    static let recording = Color.red
}

/// Visual state only; execution state still comes from the shared activity model.
enum ActivityGlassStyle: String, CaseIterable {
    case idle, working, attention, recording

    var accent: Color {
        switch self {
        case .idle: ActivityGlassPalette.slate
        case .working: ActivityGlassPalette.ember
        case .attention: ActivityGlassPalette.attention
        case .recording: ActivityGlassPalette.recording
        }
    }

    var colors: [Color] {
        switch self {
        case .idle: [ActivityGlassPalette.slate, ActivityGlassPalette.violet, .cyan]
        case .working: [ActivityGlassPalette.slate, ActivityGlassPalette.violet, ActivityGlassPalette.ember]
        case .attention: [.yellow, ActivityGlassPalette.attention, ActivityGlassPalette.ember]
        case .recording: [Color(red: 0.91, green: 0.32, blue: 0.45), .red, ActivityGlassPalette.ember]
        }
    }

    /// The colour wash sweeps around the panel, so the first colour is repeated
    /// to close the circle without a visible seam.
    var sweep: [Color] { colors + colors.dropLast().reversed() + [colors[0]] }
}

/// Static gradients with a finite crossfade on semantic state changes only.
/// No timeline, repeating animation, timer, shader, or model work sustains them.
private struct ActivityGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    let style: ActivityGlassStyle
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let dark = colorScheme == .dark
        content
            .background {
                if reduceTransparency || contrast == .increased {
                    shape.fill(Color(nsColor: .windowBackgroundColor))
                } else {
                    ZStack {
                        shape.fill(Color(nsColor: .windowBackgroundColor).opacity(dark ? 0.58 : 0.80))
                            .glassEffect(.regular.tint(style.accent.opacity(dark ? 0.20 : 0.15)), in: shape)
                        // A sweep plus a leading glow, so each state reads as its
                        // own hue instead of a faintly tinted grey.
                        shape.fill(AngularGradient(gradient: Gradient(colors: style.sweep),
                                                   center: .center, angle: .degrees(-35)))
                            .opacity(dark ? 0.34 : 0.22)
                        shape.fill(RadialGradient(gradient: Gradient(colors: [style.accent.opacity(dark ? 0.46 : 0.30), .clear]),
                                                  center: .topLeading, startRadius: 1,
                                                  endRadius: max(cornerRadius * 12, 170)))
                        shape.fill(LinearGradient(colors: [.white.opacity(dark ? 0.10 : 0.24), .clear],
                                                  startPoint: .top, endPoint: .center))
                        shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.42), style.accent.opacity(0.45), .white.opacity(0.05)],
                                                          startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                    }
                    .id(style)
                    .transition(.opacity)
                }
            }
            .overlay {
                shape.strokeBorder(contrast == .increased ? Color.primary.opacity(0.65) : style.accent.opacity(0.42), lineWidth: 1)
            }
            .shadow(color: reduceTransparency ? .clear : style.accent.opacity(dark ? 0.26 : 0.16), radius: 12, y: 3)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.55), value: style)
    }
}

/// Plain translucent glass with no state colour. The companion shell and other
/// chrome use this so only the activity status itself carries the colour.
private struct NeutralGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let dark = colorScheme == .dark
        content
            .background {
                if reduceTransparency || contrast == .increased {
                    shape.fill(Color(nsColor: .windowBackgroundColor))
                } else {
                    ZStack {
                        shape.fill(Color(nsColor: .windowBackgroundColor).opacity(dark ? 0.34 : 0.58))
                            .glassEffect(.regular, in: shape)
                        shape.fill(LinearGradient(colors: [.white.opacity(dark ? 0.08 : 0.20), .clear],
                                                  startPoint: .top, endPoint: .center))
                    }
                }
            }
            .overlay {
                shape.strokeBorder(contrast == .increased ? Color.primary.opacity(0.65) : Color.white.opacity(dark ? 0.16 : 0.34),
                                   lineWidth: 1)
            }
    }
}

extension View {
    func activityGlass(style: ActivityGlassStyle = .idle, cornerRadius: CGFloat = 16) -> some View {
        modifier(ActivityGlass(style: style, cornerRadius: cornerRadius))
    }

    func neutralGlass(cornerRadius: CGFloat = 16) -> some View {
        modifier(NeutralGlass(cornerRadius: cornerRadius))
    }
}

/// Presentation derived from the existing observable model, never a second execution state.
@MainActor
struct ActivityPresentation {
    let model: AppModel
    var roots: [ActivityRun] {
        model.topLevelCurrentActivity.sorted {
            $0.startedAt == $1.startedAt ? $0.id.uuidString < $1.id.uuidString : $0.startedAt < $1.startedAt
        }
    }
    var recording: Bool { model.capture?.isActive == true }
    var foregroundCategory: ActivityCategory {
        recording || model.captureActive || model.capture?.isFinishing == true ? .capture : .voice
    }
    var foreground: String? {
        if recording { return "Recording" }
        if model.capture?.isFinishing == true { return "Saving capture" }
        if model.captureActive { return "Capture stopped · save pending" }
        guard model.voiceEnabled else { return nil }
        switch model.voiceSnapshot.phase {
        case .listening: return "Listening"
        case .speaking: return "Speaking"
        case .thinking: return "Preparing voice reply"
        case .routing: return "Routing voice request"
        case .idle: return nil
        }
    }
    var approvals: Int {
        max(model.currentActivityRuns.filter { $0.state == .awaitingApproval }.count,
            model.todaySnapshot?.pendingSuggestionCount ?? model.suggestions.count)
    }
    var waiting: Int { roots.filter { [.waiting, .queued, .cancellationRequested].contains($0.state) }.count }
    var problems: Int {
        model.monitoredServices.filter { $0.enabled && $0.problem != nil }.count
        + model.recentActivityRuns.filter { [.failed, .interrupted, .outcomeUnknown].contains($0.state) && $0.acknowledgedAt == nil }.count
        + (model.capture?.durabilityWarning == nil ? 0 : 1)
    }
    var needsAttention: Bool { model.monitoringError != nil || problems > 0 || approvals > 0 || (model.captureActive && model.capture?.isActive != true && model.capture?.isFinishing != true) }
    var activelyWorking: Bool {
        recording || model.capture?.isFinishing == true || foreground != nil
        || model.currentActivityRuns.contains { $0.state == .running }
    }
    var style: ActivityGlassStyle {
        if recording { return .recording }
        if needsAttention { return .attention }
        return activelyWorking ? .working : .idle
    }
    var accent: Color { style.accent }
    var symbol: String {
        if recording { return "record.circle" }
        if needsAttention { return "exclamationmark.triangle" }
        if !model.monitoringReady { return "clock" }
        if activelyWorking { return "waveform.path" }
        if waiting > 0 { return "clock" }
        return model.backgroundPolicy.paused ? "pause.circle" : "circle.dotted"
    }
    var title: String {
        if let foreground { return foreground }
        if model.monitoringError != nil { return "Activity monitoring unavailable" }
        if !model.monitoringReady { return "Starting activity monitoring" }
        if roots.count == 1, let run = roots.first { return run.title }
        if roots.count > 1 { return "\(roots.count) current operations" }
        if approvals > 0 || problems > 0 { return "Needs your attention" }
        return "No work running"
    }
    var detail: String {
        if model.monitoringError != nil { return "Automatic work suspended · saved status may be stale" }
        if !model.monitoringReady { return "Waiting for saved activity status" }
        if model.capture?.durabilityWarning != nil { return "Capture checkpoint needs attention · open details" }
        if let captureID = model.capture?.activityRunID,
           let run = model.currentActivityRuns.first(where: { $0.id == captureID }),
           let stage = run.stage, !stage.isEmpty {
            return model.capture?.retainsAudio == true ? "Keeping source audio on this Mac · \(stage)" : stage
        }
        if foreground != nil, let run = roots.first(where: { $0.category == .voice }), let stage = run.stage, !stage.isEmpty {
            return stage
        }
        if foreground == nil, roots.count == 1, let run = roots.first {
            return [run.state.monitoringTitle, run.stage].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
        if !model.backgroundPolicy.reviewed { return "Automatic work awaits review" }
        if model.backgroundPolicy.paused { return "Automatic work paused · manual actions remain available" }
        return "\(model.monitoredServices.filter(\.enabled).count) automatic services enabled · details available"
    }
    var singleRun: ActivityRun? {
        if let captureID = model.capture?.activityRunID {
            return model.currentActivityRuns.first { $0.id == captureID }
        }
        if foreground != nil { return roots.first { $0.category == foregroundCategory } }
        return roots.count == 1 ? roots.first : nil
    }
    var accessibilitySummary: String {
        var parts = [title, detail, "\(roots.count) operations", "\(waiting) waiting", "\(approvals) awaiting approval", "\(problems) need attention"]
        if let run = singleRun, let completed = run.progressCompleted, let total = run.progressTotal, total > 0 {
            parts.append("\(completed) of \(total)")
        }
        return parts.joined(separator: ". ")
    }
}

/// A stable summary of all work, never a rotating carousel of individual jobs.
struct GlobalActivityBar: View {
    @Environment(AppModel.self) private var model
    @State private var expanded = false
    var body: some View {
        HStack(spacing: 14) {
            Button { expanded.toggle() } label: {
                MonitoringSummaryLabel()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $expanded, arrowEdge: .bottom) { ActivityStatusPanel().environment(model) }
            Button {
                model.toggleAutomaticWorkPause()
            } label: {
                Label(model.backgroundPolicy.paused ? "Resume" : "Pause", systemImage: model.backgroundPolicy.paused ? "play" : "pause")
            }
            .help(model.backgroundPolicy.paused ? "Resume automatic work" : "Pause new automatic work; running operations may finish")
            .controlSize(.small)
            .disabled(!model.monitoringReady || !model.backgroundPolicy.reviewed)
        }
        .padding(14)
        .frame(height: 104)
        .activityGlass(style: ActivityPresentation(model: model).style)
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

/// Shared by the companion and the menu bar; no provider calls or timers.
struct CompactActivityStatusView: View {
    @Environment(AppModel.self) private var model
    @State private var expanded = false
    var body: some View {
        Button { expanded.toggle() } label: {
            MonitoringSummaryLabel(compact: true)
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .activityGlass(style: ActivityPresentation(model: model).style, cornerRadius: 13)
                .contentShape(RoundedRectangle(cornerRadius: 13))
        }
            .buttonStyle(.plain)
            .help("Show all current operations, approvals and automatic services")
            .popover(isPresented: $expanded) { ActivityStatusPanel().environment(model) }
    }
}

struct ActivityMenuView: View {
    var body: some View { ActivityStatusPanel() }
}

struct MonitoringSummaryLabel: View {
    @Environment(AppModel.self) private var model
    var compact = false
    var showsDisclosure = true
    private var status: ActivityPresentation { ActivityPresentation(model: model) }
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 7) {
            HStack(spacing: 8) {
                Image(systemName: status.symbol).foregroundStyle(status.accent).font(.callout.weight(.semibold))
                Text(status.title).font(compact ? .caption.weight(.semibold) : .callout.weight(.semibold))
                    .foregroundStyle(.primary).lineLimit(1)
                Spacer(minLength: 4)
                if showsDisclosure { Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary) }
            }
            Text(status.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if let run = status.singleRun, let completed = run.progressCompleted, let total = run.progressTotal, total > 0 {
                HStack(spacing: 8) {
                    ProgressView(value: Double(max(0, min(completed, total))), total: Double(total))
                        .tint(status.accent)
                    Text("\(completed) of \(total)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        .fixedSize()
                }
            } else if !compact, let run = status.singleRun {
                let metadata = [run.provider, run.executionLocation, run.dataDestination].compactMap { $0 }.filter { !$0.isEmpty }
                if !metadata.isEmpty {
                    Text(metadata.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: compact ? 9 : 12) { counts }.fixedSize(horizontal: true, vertical: false)
                if compact {
                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                              alignment: .leading, spacing: 4) {
                        counts
                    }
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: 4) { counts }
                }
            }
            .font(.caption2).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.accessibilitySummary)
    }
    private func summaryCount(_ count: Int, _ title: String, _ symbol: String, _ color: Color) -> some View {
        Label("\(count) \(title)", systemImage: symbol).foregroundStyle(color)
    }
    @ViewBuilder private var counts: some View {
        if !status.roots.isEmpty { summaryCount(status.roots.count, compact ? "ops" : "operations", "square.stack.3d.up", .secondary) }
        if status.waiting > 0 { summaryCount(status.waiting, "waiting", "clock", .secondary) }
        if status.approvals > 0 { summaryCount(status.approvals, "approval", "hand.raised", ActivityGlassPalette.attention) }
        if status.problems > 0 { summaryCount(status.problems, "attention", "exclamationmark.triangle", ActivityGlassPalette.attention) }
    }
}

/// Original-color images are required here: a template menu-bar image discards the activity tint.
struct DragonActivityMenuLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var status: ActivityPresentation { ActivityPresentation(model: model) }
    var body: some View {
        ZStack {
            Image(nsImage: Self.image(for: status.style))
                .renderingMode(status.style == .idle ? .template : .original)
                .resizable().scaledToFit()
                .id(status.style)
                .transition(.opacity)
        }
        .frame(width: 18, height: 18)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: status.style)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Aitvaras. \(status.accessibilitySummary)")
    }
    /// The status item takes its width from the image's own size, not from a
    /// SwiftUI frame, so every menu image is pinned to the menu bar here.
    static let menuSide: CGFloat = 18

    static func image(for style: ActivityGlassStyle) -> NSImage {
        switch style {
        case .idle: idleImage
        case .working: activeImage
        case .attention: attentionImage
        case .recording: recordingImage
        }
    }

    private static let idleImage: NSImage = {
        guard let source = NSImage(named: "DragonMenu")?.copy() as? NSImage else { return NSImage() }
        source.size = NSSize(width: menuSide, height: menuSide)
        source.isTemplate = true
        return source
    }()
    // Cached artwork, drawn only when AppKit requests an image representation.
    private static let activeImage = gradientDragon([NSColor(ActivityGlassPalette.slate), NSColor(ActivityGlassPalette.violet), NSColor(ActivityGlassPalette.ember)])
    private static let attentionImage = gradientDragon([.systemYellow, .systemOrange, NSColor(ActivityGlassPalette.ember)])
    private static let recordingImage = gradientDragon([.systemPink, .systemRed, NSColor(ActivityGlassPalette.ember)])
    private static func gradientDragon(_ colors: [NSColor]) -> NSImage {
        guard let source = NSImage(named: "DragonMenu") else { return NSImage() }
        let image = NSImage(size: NSSize(width: menuSide, height: menuSide), flipped: false) { rect in
            source.draw(in: rect)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.cgContext.setBlendMode(.sourceAtop)
            NSGradient(colors: colors)?.draw(in: rect, angle: 35)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        image.isTemplate = false
        return image
    }
}

struct ActivityStatusPanel: View {
    @Environment(AppModel.self) private var model
    @State private var selectedRun: ActivityRun?
    var body: some View {
        if let run = selectedRun {
            VStack(alignment: .leading, spacing: 0) {
                Button("Back to Activity", systemImage: "chevron.left") { selectedRun = nil }.padding(.horizontal, 20).padding(.top, 12)
                ActivityRunDetailView(run: run).environment(model)
            }
        } else {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Activity").font(.title3.weight(.semibold))
                MonitoringSummaryLabel(showsDisclosure: false)
                if let warning = model.capture?.durabilityWarning {
                    Label("Capture save health: \(warning)", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let error = model.monitoringError {
                    Text(error).font(.callout).foregroundStyle(.orange)
                    Text("The last saved information may be stale. A blank list does not mean that nothing is happening.")
                        .font(.caption).foregroundStyle(.secondary)
                    if model.stores == nil || model.recentActivityRuns.contains(where: { $0.category == .startup && $0.state == .failed }) {
                        Button("Retry startup") { Task { await model.bootstrapIfNeeded() } }
                    }
                }
                if model.monitoringReady {
                    Text("Current operations").font(.headline)
                    if model.currentActivityRuns.isEmpty {
                        Text("No current operations recorded.").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(model.currentActivityRuns) { run in
                        Button { selectedRun = run } label: { ActivityRunRow(run: run) }.buttonStyle(.plain)
                    }
                    if !model.suggestions.isEmpty {
                        Divider()
                        Text("Pending approvals").font(.headline)
                        ForEach(model.suggestions) { suggestion in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(suggestion.title).font(.callout)
                                Text(suggestion.detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                HStack {
                                    Button("Decline") { model.reject(suggestion) }
                                    Button("Approve") { model.accept(suggestion) }
                                }.controlSize(.small)
                            }
                        }
                    }
                    Divider()
                    Text("Enabled automatic services").font(.headline)
                    if enabledServices.isEmpty {
                        Text("No automatic services enabled. Review automatic work in Settings to choose what may run.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(enabledServices) { service in ServiceStatusRow(service: service) }
                    if model.backgroundPolicy.reviewed {
                        Button(model.backgroundPolicy.paused ? "Resume automatic work" : "Pause automatic work") { model.toggleAutomaticWorkPause() }
                    }
                }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 420, height: 520)
        }
    }
    private var enabledServices: [ServiceStatus] { model.monitoredServices.filter(\.enabled) }
}

struct ActivityRunRow: View {
    let run: ActivityRun
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: run.state.monitoringIcon).foregroundStyle(run.state.monitoringColor).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(run.title).font(.callout.weight(.medium)).foregroundStyle(.primary)
                if let stage = run.stage, !stage.isEmpty { Text(stage).font(.caption).foregroundStyle(.secondary) }
                HStack(spacing: 6) {
                    Text(run.state.monitoringTitle)
                    Text("·")
                    Text(run.trigger.rawValue.capitalized)
                    if let location = run.executionLocation { Text("· \(location)") }
                }.font(.caption2).foregroundStyle(.secondary)
                if let completed = run.progressCompleted, let total = run.progressTotal, total > 0 {
                    ProgressView(value: Double(completed), total: Double(max(total, completed)))
                    Text("\(completed) of \(total)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Text(run.startedAt, style: .time).font(.caption2).foregroundStyle(.tertiary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4).contentShape(Rectangle())
    }
}

struct ServiceStatusRow: View {
    let service: ServiceStatus
    @Environment(AppModel.self) private var model
    private var status: String {
        if !service.configured { return "Not configured" }
        if !service.enabled { return "Disabled" }
        if service.paused || model.backgroundPolicy.paused { return "Paused" }
        if service.problem != nil { return "Needs attention" }
        return service.stage ?? "Waiting for next opportunity"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(service.name).font(.callout.weight(.medium))
                Spacer()
                Text(status).font(.caption).foregroundStyle(service.problem == nil ? Color.secondary : .orange)
            }
            if let problem = service.problem { Text(problem).font(.caption).foregroundStyle(.orange) }
            if let attempt = service.lastAttempt {
                Text("Last attempt: \(attempt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let last = service.lastSuccess {
                Text("Last successful check: \(last.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("No successful check recorded yet").font(.caption2).foregroundStyle(.secondary)
            }
            if let next = service.nextOpportunity {
                Text("Next opportunity: \(next.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 4)
    }
}

struct ActivityRunDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let run: ActivityRun
    @State private var events: [ActivityEvent] = []
    @State private var steps: [ActivityRunStep] = []
    @State private var error: String?
    @State private var acknowledged = false
    @State private var conversation: Conversation?
    private var current: ActivityRun {
        model.currentActivityRuns.first(where: { $0.id == run.id })
            ?? model.recentActivityRuns.first(where: { $0.id == run.id }) ?? run
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let conversation {
                SavedConversationView(conversation: conversation, onBack: { self.conversation = nil })
                    .environment(model)
            } else {
            HStack {
                Text(current.title).font(.title3.weight(.semibold))
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.escape)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent("Status", value: current.state.monitoringTitle)
                    if current.state == .awaitingApproval {
                        Text("Review the proposed action in Home or Chat. Nothing executes until you approve it.")
                            .font(.callout).foregroundStyle(.orange)
                    }
                    if !current.state.isTerminal {
                        if model.canStopActivityRun(current) {
                            Button("Stop operation", systemImage: "stop.circle") { model.cancelActivityRun(current.id) }
                        } else {
                            Text(current.state == .cancellationRequested ? "Cancellation requested; waiting for the operation to stop." : "Stop is not available for this operation.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    detail("Stage", current.stage)
                    LabeledContent("Trigger", value: current.trigger.rawValue.capitalized)
                    LabeledContent("Category", value: current.category.rawValue.capitalized)
                    LabeledContent("Started", value: current.startedAt.formatted(date: .abbreviated, time: .standard))
                    LabeledContent("Elapsed", value: elapsed)
                    detail("Provider", current.provider)
                    detail("Execution", current.executionLocation)
                    detail("Data accessed", current.dataAccess)
                    detail("Destination", current.dataDestination)
                    detail("Result", current.outcome)
                    if [.failed, .interrupted, .outcomeUnknown].contains(current.state),
                       current.acknowledgedAt == nil, !acknowledged {
                        VStack(alignment: .leading, spacing: 4) {
                            Button("Mark reviewed") {
                                model.acknowledgeActivityRun(current.id)
                                if let updated = try? model.stores?.activityRun(id: current.id) {
                                    acknowledged = updated.acknowledgedAt != nil
                                }
                            }
                            Text("Removes this problem from Home attention. It does not retry or undo the operation.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let reference = current.referenceID, let id = UUID(uuidString: reference) {
                        if current.category == .capture {
                            Button("Open saved capture") {
                                do {
                                    if let record = try model.stores?.captureRecord(id: id) { CaptureWindows.shared.showResult(record: record, model: model) }
                                    else { error = "No saved capture is available for this operation yet." }
                                } catch { self.error = "The saved capture could not be loaded." }
                            }
                        } else if current.category == .chat || current.category == .voice {
                            Button("Open conversation") {
                                do {
                                    conversation = try model.stores?.conversation(id: id)
                                    if conversation == nil { error = "No saved conversation is linked to this operation." }
                                }
                                catch { self.error = "The conversation could not be loaded." }
                            }
                        }
                    }
                    DisclosureGroup("Technical identifiers") {
                        if let parent = current.parentID { detail("Parent operation", parent.uuidString) }
                        if let reference = current.referenceID { detail("Reference", reference) }
                    }
                    if let error { Text(error).font(.caption).foregroundStyle(.orange) }
                    if !steps.isEmpty {
                        Divider()
                        Text("Stages").font(.headline)
                        ForEach(steps) { step in
                            HStack(alignment: .top) {
                                Image(systemName: step.state.monitoringIcon).foregroundStyle(step.state.monitoringColor)
                                Text(step.stage).frame(maxWidth: .infinity, alignment: .leading)
                                Text(step.timestamp.formatted(date: .omitted, time: .standard)).foregroundStyle(.secondary)
                            }.font(.caption)
                        }
                    }
                    if !events.isEmpty {
                        Divider()
                        Text("Recorded events").font(.headline)
                        ForEach(events) { event in
                            DisclosureGroup {
                                Text(event.timestamp.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.secondary)
                                if let json = event.detailJSON, !json.isEmpty {
                                    DisclosureGroup("Technical details") {
                                        Text(json).font(.caption.monospaced()).textSelection(.enabled)
                                    }
                                }
                            } label: { Text(event.summary).font(.callout) }
                        }
                    }
                }.textSelection(.enabled)
            }
            }
        }.padding(24).frame(width: 570, height: 560)
        .task(id: current.updatedAt) {
            do {
                events = try model.stores?.activityEvents(runID: run.id) ?? []
                steps = try model.stores?.activityRunSteps(runID: run.id) ?? []
            }
            catch { self.error = "Recorded events could not be loaded." }
        }
    }
    @ViewBuilder private func detail(_ title: String, _ value: String?) -> some View {
        if let value, !value.isEmpty { LabeledContent(title, value: value) }
        else { LabeledContent(title, value: "Not recorded").foregroundStyle(.secondary) }
    }
    private var elapsed: String {
        let seconds = max(0, Int((current.finishedAt ?? .now).timeIntervalSince(current.startedAt)))
        return seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s"
    }
}

private struct SavedConversationView: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation
    let onBack: () -> Void
    @State private var messages: [StoredMessage] = []
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("Back to Operation", systemImage: "chevron.left", action: onBack)
            Text(conversation.title).font(.headline)
            if let error { Text(error).foregroundStyle(.orange) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(messages) { message in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(message.role.capitalized).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(message.content).textSelection(.enabled)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            do { messages = try model.stores?.messages(in: conversation.id) ?? [] }
            catch { self.error = "Saved messages could not be loaded." }
        }
    }
}

struct BackgroundReviewView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = BackgroundWorkPolicy()
    @State private var loaded = false
    @State private var saved = false
    @State private var pendingDeliveryCount: Int?
    @State private var reviewedPendingDeliveries = false
    var body: some View {
        Form {
            Section("Your choice, once") {
                Text("Automatic work stays off until you explicitly save your choices here. Existing connection and model settings are preserved. Manual actions remain available.")
                if !model.backgroundPolicy.reviewed {
                    Label("Not reviewed · no automatic work permitted", systemImage: "hand.raised").foregroundStyle(.orange)
                }
                Toggle("Pause all automatic work", isOn: $draft.paused)
                    .onChange(of: draft.paused) { saved = false }
                Text("Pausing prevents new automatic work. An operation already in progress may finish; its status remains visible.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Allow these features to run automatically") {
                ForEach(BackgroundFeature.allCases, id: \.self) { feature in
                    Toggle(isOn: Binding(get: { draft.allowed.contains(feature) }, set: { enabled in
                        if enabled { draft.allowed.insert(feature) } else { draft.allowed.remove(feature) }
                        saved = false
                    })) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(feature.monitoringTitle)
                            Text(feature.monitoringDescription).font(.caption).foregroundStyle(.secondary)
                            if let status = model.monitoredServices.first(where: { $0.id == feature.rawValue }) {
                                Text(status.stage ?? "No schedule information available").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Section("Held work before resuming") {
                if let count = pendingDeliveryCount {
                    Text("\(count) external deliveries are waiting. Expiry and duplicate-prevention rules still apply.")
                    if count > 0 {
                        Toggle("I reviewed this queue and allow eligible saved deliveries to resume", isOn: $reviewedPendingDeliveries)
                        Text("Destination: your configured phone-notification connection. Leave external delivery off to keep this queue held.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("The pending delivery queue could not be checked. External delivery cannot be enabled here yet.").foregroundStyle(.orange)
                }
                Text("Conversation recovery is limited to three archived conversations per resumption. Missed routine schedules retain their existing run windows; uncertain external actions are not replayed. Old focus sessions and spoken updates never resume automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Save automatic-work choices") {
                        draft.reviewed = true
                        model.saveBackgroundPolicy(draft)
                        saved = model.backgroundPolicy == draft
                    }.buttonStyle(.borderedProminent).disabled(!model.monitoringReady ||
                        (draft.allowed.contains(.delivery) && !draft.paused &&
                            (pendingDeliveryCount == nil || (pendingDeliveryCount! > 0 && !reviewedPendingDeliveries))))
                    if saved { Label("Choices saved", systemImage: "checkmark.circle").foregroundStyle(.green) }
                }
                Text("Saving an empty selection is valid: all automatic features stay off. Enabling a feature does not configure missing accounts or grant new system permissions.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Automatic work")
        .disabled(!loaded)
        .task { loadSavedPolicy() }
        .onChange(of: model.monitoringReady) { loadSavedPolicy() }
    }
    private func loadSavedPolicy() {
        guard !loaded, model.monitoringReady else { return }
        draft = model.backgroundPolicy
        pendingDeliveryCount = try? model.stores?.pendingPhoneNotificationCount()
        loaded = true
    }
}

extension ActivityRunState {
    var monitoringTitle: String {
        switch self {
        case .awaitingApproval: "Awaiting approval"
        case .cancellationRequested: "Cancellation requested"
        case .outcomeUnknown: "Outcome unknown"
        default: rawValue.capitalized
        }
    }
    var monitoringIcon: String {
        switch self {
        case .succeeded: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .cancelled: "xmark.circle"
        case .interrupted, .outcomeUnknown: "questionmark.circle"
        case .awaitingApproval: "hand.raised"
        case .queued, .waiting, .cancellationRequested: "clock"
        case .running: "waveform.path"
        }
    }
    var monitoringColor: Color {
        switch self {
        case .succeeded: .green
        case .failed: .red
        case .interrupted, .outcomeUnknown, .awaitingApproval: .orange
        case .running: .accentColor
        default: .secondary
        }
    }
}

private extension BackgroundFeature {
    var monitoringDescription: String {
        switch self {
        case .mail: "Check local Mail for new messages on its configured interval. Message text is triaged by the local model; phone delivery is separately controlled."
        case .notifications: "Read only the notification sources you enabled, on their configured interval. Local processing; urgent phone delivery requires separate permission."
        case .connectors: "Poll configured integration endpoints on their saved intervals. Data comes from those services; actions still follow connector approval rules."
        case .indexing: "Watch selected available folders for changes. File text goes to the configured local embedding service and local search database."
        case .archiving: "After conversations end, use the local background model to save summaries and memory candidates. Original messages remain stored."
        case .memory:
            "Update saved memory. Provider: \(CloudAgentSettings.selection(for: .nightlyMemory).displayName). Data: \(CloudAgentFeature.nightlyMemory.dataCategories.joined(separator: ", ")). \(CloudAgentFeature.nightlyMemory.toolAccessDisclosure)"
        case .routineReview:
            "Propose routines; never approve them automatically. Provider: \(CloudAgentSettings.selection(for: .routineReview).displayName). Data: \(CloudAgentFeature.routineReview.dataCategories.joined(separator: ", ")). \(CloudAgentFeature.routineReview.toolAccessDisclosure)"
        case .routines: "Run only separately reviewed, activated routines at their saved schedules. Their fixed tools use the destinations shown in each routine."
        case .delivery: "Send queued updates to the configured phone-notification destination. This transmits notification content outside this Mac."
        case .focus: "Observe configured focus signals only during a focus session you explicitly start."
        }
    }
}
