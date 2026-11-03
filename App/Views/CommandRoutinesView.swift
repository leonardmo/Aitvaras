import SwiftUI
import AitvarasCore
import AitvarasStore

struct CommandRoutinesView: View {
    let model: AppModel
    @State private var editing: CommandRoutine?
    @State private var showDismissed = false

    private var suggestions: [CommandRoutine] {
        model.commandRoutines.filter { $0.statusValue == .suggested }
    }
    private var shortcuts: [CommandRoutine] {
        model.commandRoutines.filter {
            $0.triggerKindValue == .phrase && $0.statusValue != .dismissed
        }
    }
    private var schedules: [CommandRoutine] {
        model.commandRoutines.filter {
            $0.triggerKindValue == .schedule
                && $0.statusValue != .suggested && $0.statusValue != .dismissed
        }
    }
    private var dismissed: [CommandRoutine] {
        model.commandRoutines.filter { $0.statusValue == .dismissed }
    }

    var body: some View {
        ScrollView {
            snapshotContent
        }
        .navigationTitle("Shortcuts")
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") {
                model.refreshSidebandData()
            }
        }
        .sheet(item: $editing) { routine in
            RoutineEditSheet(routine: routine) { updated in
                model.saveCommandRoutine(updated)
                editing = nil
            }
        }
    }

    /// The same hierarchy without its platform ScrollView, used by the
    /// isolated screenshot seam because offscreen AppKit capture omits hosted
    /// scroll content.
    var snapshotContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            intro

            if !suggestions.isEmpty {
                routineSection(
                    title: "Waiting for your approval",
                    subtitle: "A time pattern never becomes active by itself.",
                    routines: suggestions)
            }
            routineSection(
                title: "Command shortcuts",
                subtitle: "Exact phrases that skip the AI model and follow the shown path.",
                routines: shortcuts,
                empty: "No shortcut learned yet. The third identical successful command creates one.")
            routineSection(
                title: "Scheduled routines",
                subtitle: "Only schedules you explicitly activate can run.",
                routines: schedules,
                empty: "No scheduled routine is active or paused.")

            if !dismissed.isEmpty {
                DisclosureGroup("Dismissed patterns (\(dismissed.count))", isExpanded: $showDismissed) {
                    VStack(spacing: 12) {
                        ForEach(dismissed) { routine in
                            RoutineWorkflowCard(
                                routine: routine,
                                onEdit: { editing = routine },
                                onStatus: { model.setCommandRoutineStatus(routine, to: $0) },
                                onDelete: { model.deleteCommandRoutine(routine) })
                        }
                    }
                    .padding(.top, 10)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 920, alignment: .leading)
        .padding(24)
        .frame(maxWidth: .infinity)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Fast paths you can inspect", systemImage: "bolt.fill")
                .font(.title2.weight(.semibold))
            Text("Exact shortcuts are learned after three identical, successful low-risk commands. Schedules require your approval.")
                .foregroundStyle(.secondary)
            DisclosureGroup("How shortcuts are learned") {
                Text("Aitvaras learns an exact shortcut only after the same low-risk command completes through the same fixed tool path three times. It stores no model reasoning or tool output. If enabled under Models → Cloud agents, Claude or Codex may improve the title and explanation, but can never change the trigger, arguments, risk, or execution path.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                Label("Exact phrase", systemImage: "text.quote")
                Label("No model", systemImage: "cpu")
                Label("Visible audit trail", systemImage: "point.3.connected.trianglepath.dotted")
                Label("Schedules require approval", systemImage: "hand.raised")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
        }
        .padding(18)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private func routineSection(
        title: String,
        subtitle: String,
        routines: [CommandRoutine],
        empty: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            if routines.isEmpty, let empty {
                Text(empty)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 12)
            } else {
                ForEach(routines) { routine in
                    RoutineWorkflowCard(
                        routine: routine,
                        onEdit: { editing = routine },
                        onStatus: { model.setCommandRoutineStatus(routine, to: $0) },
                        onDelete: { model.deleteCommandRoutine(routine) })
                }
            }
        }
    }
}

private struct RoutineWorkflowCard: View {
    let routine: CommandRoutine
    let onEdit: () -> Void
    let onStatus: (CommandRoutine.Status) -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(routine.title).font(.headline)
                        statusBadge
                    }
                    Text(routine.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 14)
                actionButtons
            }

            ViewThatFits(in: .horizontal) {
                workflowNodes.fixedSize(horizontal: true, vertical: false)
                ScrollView(.horizontal, showsIndicators: false) {
                    workflowNodes
                }
            }
            .frame(height: 92)

            HStack(spacing: 14) {
                Label("\(routine.evidenceCount) observed", systemImage: "chart.bar.xaxis")
                if routine.runCount > 0 {
                    Label("\(routine.runCount) fast runs", systemImage: "bolt")
                }
                if let last = routine.lastRunAt {
                    Text("Last ran \(last, style: .relative)")
                }
                if let provider = routine.reviewProvider {
                    Label(
                        "Reviewed by \(provider == "claude" ? "Claude" : "Codex")",
                        systemImage: "checkmark.seal")
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(.quaternary))
    }

    private var workflowNodes: some View {
        HStack(spacing: 8) {
            triggerNode
            Image(systemName: "arrow.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
            ForEach(Array(routine.steps.enumerated()), id: \.offset) { index, step in
                stepNode(step, number: index + 1)
                if index < routine.steps.count - 1 {
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Done")
        }
        .padding(.vertical, 2)
    }

    private var statusBadge: some View {
        Text(routine.statusValue == .suggested ? "Needs approval" : routine.statusValue.rawValue.capitalized)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(statusColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(statusColor.opacity(0.12), in: Capsule())
    }

    private var statusColor: Color {
        switch routine.statusValue {
        case .suggested: .orange
        case .active: .green
        case .paused, .dismissed: .secondary
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 6) {
            switch routine.statusValue {
            case .suggested:
                Button("Review", action: onEdit).controlSize(.small)
                Button("Dismiss") { onStatus(.dismissed) }.controlSize(.small)
                Button("Activate") { onStatus(.active) }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            case .active:
                Button("Edit", action: onEdit).controlSize(.small)
                Button("Pause") { onStatus(.paused) }.controlSize(.small)
            case .paused:
                Button("Edit", action: onEdit).controlSize(.small)
                Button("Resume") { onStatus(.active) }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                Button("Delete", role: .destructive, action: onDelete).controlSize(.small)
            case .dismissed:
                Button("Review", action: onEdit).controlSize(.small)
                Button("Restore") { onStatus(.suggested) }.controlSize(.small)
                Button("Delete", role: .destructive, action: onDelete).controlSize(.small)
            }
        }
    }

    private var triggerNode: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(routine.triggerKindValue == .phrase ? "When you say" : "At this time",
                  systemImage: routine.triggerKindValue == .phrase ? "quote.bubble" : "clock")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(triggerText)
                .font(.callout.weight(.medium))
                .lineLimit(2)
        }
        .padding(10)
        .frame(minWidth: 150, alignment: .leading)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    private func stepNode(_ step: CommandRoutineStep, number: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("STEP \(number)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(step.label.capitalized)
                .font(.callout.weight(.medium))
            Text(step.namespacedToolName)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
            if step.argumentsJSON != "{}" {
                Text(step.argumentsJSON)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .frame(minWidth: 160, alignment: .leading)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    }

    private var triggerText: String {
        switch routine.triggerKindValue {
        case .phrase:
            return routine.phrases.map { "“\($0)”" }.joined(separator: " or ")
        case .schedule:
            let minute = routine.scheduleMinuteOfDay ?? 0
            let time = String(format: "%02d:%02d", minute / 60, minute % 60)
            return "\(weekdayText(mask: routine.scheduleWeekdayMask ?? 0)) · \(time)"
        }
    }

    private func weekdayText(mask: Int) -> String {
        if mask == 127 { return "Every day" }
        let weekdayMask = (2...6).reduce(0) { $0 | (1 << ($1 - 1)) }
        if mask == weekdayMask { return "Weekdays" }
        let names = Calendar.current.shortWeekdaySymbols
        return (1...7).compactMap { weekday in
            mask & (1 << (weekday - 1)) != 0 ? names[weekday - 1] : nil
        }.joined(separator: ", ")
    }
}

private struct RoutineEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let original: CommandRoutine
    let onSave: (CommandRoutine) -> Void

    @State private var title: String
    @State private var phrases: String
    @State private var time: Date
    @State private var weekdays: Set<Int>
    @State private var steps: [CommandRoutineStep]
    @State private var error: String?

    init(routine: CommandRoutine, onSave: @escaping (CommandRoutine) -> Void) {
        original = routine
        self.onSave = onSave
        _title = State(initialValue: routine.title)
        _phrases = State(initialValue: routine.phrases.joined(separator: "\n"))
        let minute = routine.scheduleMinuteOfDay ?? 9 * 60
        _time = State(initialValue: Calendar.current.date(
            bySettingHour: minute / 60, minute: minute % 60, second: 0,
            of: .now) ?? .now)
        _weekdays = State(initialValue: Set((1...7).filter {
            (routine.scheduleWeekdayMask ?? 0) & (1 << ($0 - 1)) != 0
        }))
        _steps = State(initialValue: routine.steps)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(original.statusValue == .suggested ? "Review automation" : "Edit routine")
                .font(.title2.weight(.semibold))
            Form {
                TextField("Name", text: $title)
                if original.triggerKindValue == .phrase {
                    Section("Exact spoken or typed phrases") {
                        TextEditor(text: $phrases)
                            .font(.body.monospaced())
                            .frame(minHeight: 62)
                        Text("One phrase per line. Matching ignores capitalization, accents and punctuation—but does not guess similar wording.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Section("Schedule") {
                        DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                        HStack {
                            ForEach(1...7, id: \.self) { day in
                                Button(Calendar.current.veryShortWeekdaySymbols[day - 1]) {
                                    if weekdays.contains(day) { weekdays.remove(day) }
                                    else { weekdays.insert(day) }
                                }
                                .buttonStyle(.bordered)
                                .tint(weekdays.contains(day) ? .accentColor : .secondary)
                            }
                        }
                    }
                }

                Section("Fixed workflow") {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Label("\(index + 1). \(step.namespacedToolName)", systemImage: "gearshape")
                                    .font(.callout.weight(.medium))
                                Spacer()
                                Button("Move up", systemImage: "arrow.up") {
                                    steps.swapAt(index, index - 1)
                                }
                                .labelStyle(.iconOnly).disabled(index == 0)
                                Button("Move down", systemImage: "arrow.down") {
                                    steps.swapAt(index, index + 1)
                                }
                                .labelStyle(.iconOnly).disabled(index == steps.count - 1)
                                Button("Remove", systemImage: "trash", role: .destructive) {
                                    steps.remove(at: index)
                                }
                                .labelStyle(.iconOnly)
                            }
                            TextEditor(text: Binding(
                                get: { steps.indices.contains(index) ? steps[index].argumentsJSON : "" },
                                set: { if steps.indices.contains(index) { steps[index].argumentsJSON = $0 } }))
                                .font(.caption.monospaced())
                                .frame(minHeight: 58)
                        }
                        .padding(.vertical, 5)
                    }
                }
            }
            .formStyle(.grouped)

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 650, height: 610)
    }

    private func save() {
        let canonicalSteps = steps.compactMap { step -> CommandRoutineStep? in
            guard let canonical = CommandRoutineStep.canonicalJSON(step.argumentsJSON) else {
                return nil
            }
            return CommandRoutineStep(
                connectorID: step.connectorID, toolName: step.toolName,
                argumentsJSON: canonical, risk: step.risk, label: step.label)
        }
        guard canonicalSteps.count == steps.count, !canonicalSteps.isEmpty else {
            error = "Every step needs a valid JSON object."
            return
        }
        let minute = Calendar.current.component(.hour, from: time) * 60
            + Calendar.current.component(.minute, from: time)
        let mask = weekdays.reduce(0) { $0 | (1 << ($1 - 1)) }
        do {
            let updated = try CommandRoutine(
                id: original.id,
                title: title,
                triggerKind: original.triggerKindValue,
                phrases: original.triggerKindValue == .phrase
                    ? phrases.split(whereSeparator: \.isNewline).map(String.init) : [],
                scheduleMinuteOfDay: original.triggerKindValue == .schedule ? minute : nil,
                scheduleWeekdayMask: original.triggerKindValue == .schedule ? mask : nil,
                steps: canonicalSteps,
                status: original.statusValue,
                evidenceCount: original.evidenceCount,
                explanation: original.explanation,
                dedupeKey: original.dedupeKey,
                createdAt: original.createdAt,
                updatedAt: .now,
                lastRunAt: original.lastRunAt,
                lastRunSlot: original.lastRunSlot,
                runCount: original.runCount)
            onSave(updated)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
