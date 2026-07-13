import SwiftUI
import AitvarasCore
import AitvarasStore

/// "What does Aitvaras know about me?" (MASTERPLAN §20) — the transparency
/// surface for the fact store: browse, search, correct, approve, delete.
/// Everything shown is editable in place; a correction supersedes the old
/// fact (history preserved) and counts as high-authority signal.
struct MemoryView: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case facts = "Facts"
        case entities = "People & Things"
        case questions = "Questions"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var model
    @State private var tab: Tab = .facts

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding()

            switch tab {
            case .facts: FactsTab()
            case .entities: EntitiesTab()
            case .questions: QuestionsTab()
            }
        }
        .navigationTitle("Memory")
    }
}

// MARK: - Facts

private struct FactsTab: View {
    @Environment(AppModel.self) private var model
    @State private var facts: [MemoryFact] = []
    @State private var pendingReview: [MemoryFact] = []
    @State private var search = ""
    @State private var kindFilter: MemoryFact.Kind?
    @State private var showHistory = false
    @State private var editing: MemoryFact?

    var body: some View {
        List {
            if !pendingReview.isEmpty {
                Section("Waiting for your review") {
                    ForEach(pendingReview, id: \.id) { fact in
                        HStack(alignment: .top) {
                            FactRow(fact: fact)
                            Spacer()
                            Button("Approve") { approve(fact) }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            Button("Delete", role: .destructive) { delete(fact) }
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                        }
                    }
                }
            }

            Section {
                ForEach(visibleFacts, id: \.id) { fact in
                    Button { editing = fact } label: {
                        FactRow(fact: fact)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                HStack {
                    Text(showHistory ? "All facts (incl. superseded)" : "Current facts")
                    Spacer()
                    Text("\(visibleFacts.count)")
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .searchable(text: $search, prompt: "Search facts")
        .overlay {
            if facts.isEmpty && pendingReview.isEmpty {
                ContentUnavailableView(
                    "Nothing remembered yet",
                    systemImage: "brain",
                    description: Text("Tell Aitvaras \"remember that …\", or just talk to her — conversations and the nightly consolidation fill this in."))
            }
        }
        .toolbar {
            Menu {
                Button("All kinds") { kindFilter = nil }
                Divider()
                ForEach(MemoryFact.Kind.allCases, id: \.self) { kind in
                    Button(kind.rawValue.capitalized) { kindFilter = kind }
                }
            } label: {
                Label(kindFilter?.rawValue.capitalized ?? "All kinds",
                      systemImage: "line.3.horizontal.decrease.circle")
            }
            Toggle("History", isOn: $showHistory)
            Button("Refresh", systemImage: "arrow.clockwise") { reload() }
        }
        .sheet(item: $editing) { fact in
            FactEditorSheet(fact: fact) { reload() }
                .environment(model)
        }
        .task { reload() }
    }

    private var visibleFacts: [MemoryFact] {
        facts.filter { fact in
            (showHistory || fact.isCurrentlyValid)
                && (kindFilter == nil || fact.kindValue == kindFilter)
                && (search.isEmpty
                    || fact.text.localizedCaseInsensitiveContains(search)
                    || fact.entitiesText.localizedCaseInsensitiveContains(search))
        }
    }

    private func reload() {
        guard let stores = model.stores else { return }
        facts = ((try? stores.allFacts()) ?? []).filter { !$0.needsReview }
        pendingReview = (try? stores.factsNeedingReview()) ?? []
    }

    private func approve(_ fact: MemoryFact) {
        try? model.stores?.approveFact(fact.id)
        reload()
    }

    private func delete(_ fact: MemoryFact) {
        try? model.stores?.deleteFact(fact.id)
        reload()
    }
}

private struct FactRow: View {
    let fact: MemoryFact

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(fact.text)
                .strikethrough(!fact.isCurrentlyValid, color: .secondary)
                .foregroundStyle(fact.isCurrentlyValid ? .primary : .secondary)
            HStack(spacing: 6) {
                chip(fact.kindValue.rawValue, color: .teal)
                chip(sourceLabel, color: sourceColor)
                if !fact.entitiesText.isEmpty {
                    chip(fact.entitiesText, color: .indigo)
                }
                Text(fact.createdAt, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if !fact.isCurrentlyValid {
                    Text("superseded")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var sourceLabel: String {
        switch fact.sourceValue {
        case .userStated: "you said"
        case .userAnswered: "you answered"
        case .extracted: "learned"
        case .reflected: "inferred"
        }
    }

    private var sourceColor: Color {
        switch fact.sourceValue {
        case .userStated, .userAnswered: .green
        case .extracted: .blue
        case .reflected: .purple
        }
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }
}

/// Edit = correct: the edited text becomes a new user-stated fact that
/// supersedes the original (validity timeline stays inspectable).
private struct FactEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let fact: MemoryFact
    let onChange: () -> Void
    @State private var text: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Fact")
                .font(.title3.weight(.semibold))
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 70)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Known since") { Text(fact.validFrom, style: .date) }
                if let end = fact.validTo {
                    LabeledContent("Superseded") { Text(end, style: .date) }
                }
                LabeledContent("Source") { Text(fact.source.replacingOccurrences(of: "_", with: " ")) }
                LabeledContent("Importance") { Text("\(fact.importance)/10") }
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            Spacer()
            HStack {
                Button("Delete", role: .destructive) {
                    try? model.stores?.deleteFact(fact.id)
                    onChange()
                    dismiss()
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                Button("Save correction") {
                    save()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || text == fact.text || !fact.isCurrentlyValid)
            }
        }
        .padding(24)
        .frame(width: 480, height: 340)
        .onAppear { text = fact.text }
    }

    private func save() {
        guard let stores = model.stores else { return }
        let replacement = MemoryFact(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            entitiesText: fact.entitiesText,
            kind: fact.kindValue,
            importance: fact.importance,
            confidence: 1.0,
            source: .userStated)
        try? stores.saveFact(replacement)
        try? stores.supersedeFact(fact.id, by: replacement.id)
        onChange()
    }
}

// MARK: - Entities

private struct EntitiesTab: View {
    @Environment(AppModel.self) private var model
    @State private var entities: [MemoryEntity] = []
    @State private var selected: MemoryEntity?

    var body: some View {
        List(entities, id: \.id) { entity in
            Button { selected = entity } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon(for: entity.kindValue))
                        .foregroundStyle(.teal)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entity.name)
                        if !entity.summary.isEmpty {
                            Text(entity.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .overlay {
            if entities.isEmpty {
                ContentUnavailableView(
                    "No people or things yet",
                    systemImage: "person.2",
                    description: Text("Entities appear as facts mention people, places, courses and systems."))
            }
        }
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") { reload() }
        }
        .sheet(item: $selected) { entity in
            EntityFactsSheet(entity: entity)
                .environment(model)
        }
        .task { reload() }
    }

    private func reload() {
        entities = (try? model.stores?.entities()) ?? []
    }

    private func icon(for kind: MemoryEntity.Kind) -> String {
        switch kind {
        case .person: "person"
        case .place: "mappin.and.ellipse"
        case .course: "book"
        case .system: "server.rack"
        case .org: "building.2"
        case .other: "tag"
        }
    }
}

private struct EntityFactsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let entity: MemoryEntity
    @State private var facts: [MemoryFact] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(entity.name)
                .font(.title3.weight(.semibold))
            if !entity.summary.isEmpty {
                Text(entity.summary).foregroundStyle(.secondary)
            }
            if facts.isEmpty {
                Text("No current facts reference this entity.")
                    .foregroundStyle(.tertiary)
            } else {
                List(facts, id: \.id) { FactRow(fact: $0) }
                    .listStyle(.plain)
            }
            Spacer()
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.escape)
            }
        }
        .padding(24)
        .frame(width: 480, height: 380)
        .task {
            facts = (try? model.stores?.facts(forEntity: entity.id)) ?? []
        }
    }
}

// MARK: - Questions

private struct QuestionsTab: View {
    @Environment(AppModel.self) private var model
    @State private var open: [CuriosityQuestion] = []

    var body: some View {
        List {
            Section("Aitvaras wants to know") {
                ForEach(open, id: \.id) { question in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(question.text)
                            if !question.motivation.isEmpty {
                                Text(question.motivation)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Dismiss") { dismissQuestion(question) }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .overlay {
            if open.isEmpty {
                ContentUnavailableView(
                    "No open questions",
                    systemImage: "questionmark.bubble",
                    description: Text("The nightly consolidation queues questions when an answer would make Aitvaras more useful. Answer them in chat: \"was willst du wissen?\""))
            }
        }
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") { reload() }
        }
        .task { reload() }
    }

    private func reload() {
        open = (try? model.stores?.openQuestions()) ?? []
    }

    private func dismissQuestion(_ question: CuriosityQuestion) {
        try? model.stores?.setQuestionStatus(question.id, to: .dismissed)
        reload()
    }
}
