import SwiftUI
import AppKit
import AitvarasStore

private struct NewsTopicEditorState: Identifiable {
    var topic: NewsTopic
    var isNew: Bool
    var id: UUID { topic.id }
}

struct NewsView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedArticleID: UUID?
    @State private var editor: NewsTopicEditorState?
    @State private var showingPreferences = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.newsTopics.isEmpty {
                emptyState
            } else {
                HSplitView {
                    articleList
                        .frame(minWidth: 310, idealWidth: 370, maxWidth: 450)
                    articleReader
                        .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle("News")
        .toolbar {
            ToolbarItemGroup {
                if model.newsIsNarrating {
                    Button("Stop reading", systemImage: "stop.fill") {
                        model.stopNewsNarration()
                    }
                } else if !model.newsArticles.isEmpty {
                    Button("Listen to briefing", systemImage: "headphones") {
                        model.readNewsBriefing(topicID: model.selectedNewsTopicID)
                    }
                }
                Button("Refresh", systemImage: "arrow.clockwise") {
                    model.refreshNews(topicID: model.selectedNewsTopicID)
                }
                .disabled(model.newsIsRefreshing)
                Button("News settings", systemImage: "slider.horizontal.3") {
                    showingPreferences = true
                }
                Button("Add topic", systemImage: "plus") {
                    presentNewTopicEditor()
                }
            }
        }
        .sheet(item: $editor) { state in
            NewsTopicEditor(topic: state.topic, isNew: state.isNew)
                .environment(model)
        }
        .sheet(isPresented: $showingPreferences) {
            NewsPreferencesView()
                .environment(model)
        }
        .onAppear {
            model.refreshNewsState(topicID: model.selectedNewsTopicID)
            chooseFirstArticleIfNeeded()
        }
        .onChange(of: model.newsArticles) { chooseFirstArticleIfNeeded() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("A calm, source-first briefing")
                        .font(.title2.weight(.semibold))
                    Text("Curated publishers, no breaking-news interruptions, and no spillover into Memory or Activity.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.newsIsRefreshing {
                    ProgressView().controlSize(.small)
                    Text("Checking sources…").font(.caption).foregroundStyle(.secondary)
                }
                Button("Add topic", systemImage: "plus") {
                    presentNewTopicEditor()
                }
                .buttonStyle(.bordered)
            }

            if !model.newsTopics.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        topicButton(title: "All topics", id: nil, icon: "square.grid.2x2")
                        ForEach(model.newsTopics) { topic in
                            topicButton(
                                title: topic.name,
                                id: topic.id,
                                icon: topic.importanceValue == .high ? "star.fill" : "number")
                            .contextMenu {
                                Button("Edit") {
                                    editor = NewsTopicEditorState(topic: topic, isNew: false)
                                }
                                Button("Delete", role: .destructive) {
                                    model.deleteNewsTopic(topic.id)
                                }
                            }
                        }
                    }
                }
            }

            if let message = model.newsRefreshMessage {
                Label(message, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(.bar)
    }

    private func topicButton(title: String, id: UUID?, icon: String) -> some View {
        let selected = model.selectedNewsTopicID == id
        return Button {
            selectedArticleID = nil
            model.selectNewsTopic(id)
        } label: {
            Label(title, systemImage: icon)
                .font(.callout.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(selected ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.055))
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(selected ? Color.accentColor.opacity(0.5) : .clear))
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Choose what deserves your attention", systemImage: "newspaper")
        } description: {
            Text("Add topics such as AI tools, European policy or energy. Give each one an importance and update interval; Aitvaras builds a separate, quiet feed from curated sources.")
        } actions: {
            Button("Add first topic") {
                presentNewTopicEditor()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var articleList: some View {
        List(selection: $selectedArticleID) {
            ForEach(model.newsArticles) { article in
                NewsArticleRow(article: article)
                    .tag(article.id)
            }
        }
        .listStyle(.inset)
        .overlay {
            if model.newsArticles.isEmpty {
                ContentUnavailableView(
                    "No matching stories yet",
                    systemImage: "text.magnifyingglass",
                    description: Text("Refresh the topic or broaden its search terms."))
            }
        }
        .onChange(of: selectedArticleID) {
            guard let selectedArticleID else { return }
            model.markNewsArticleRead(selectedArticleID)
        }
    }

    @ViewBuilder private var articleReader: some View {
        if let article = selectedArticle {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let imageURL = article.imageURL.flatMap(URL.init(string:)) {
                        SafeNewsImage(url: imageURL)
                        .frame(maxWidth: .infinity, minHeight: 220, maxHeight: 330)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                    } else {
                        NewsImagePlaceholder()
                            .frame(maxWidth: .infinity, minHeight: 180, maxHeight: 230)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Text(article.sourceName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tint)
                            Text(article.publishedAt, style: .relative)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if article.corroborationCount > 1 {
                                Label("\(article.corroborationCount) sources", systemImage: "checkmark.seal")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(article.title)
                            .font(.largeTitle.weight(.bold))
                            .textSelection(.enabled)
                        if !article.summary.isEmpty {
                            Text(article.summary)
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .lineSpacing(5)
                                .textSelection(.enabled)
                        } else {
                            Text("This source supplied a headline but no reusable summary. Open the original for the full reporting.")
                                .foregroundStyle(.secondary)
                                .italic()
                        }
                    }

                    HStack(spacing: 12) {
                        let isThisArticlePlaying = model.newsIsNarrating
                        Button(
                            isThisArticlePlaying ? "Stop" : "Listen",
                            systemImage: isThisArticlePlaying ? "stop.fill" : "play.fill"
                        ) {
                            if isThisArticlePlaying {
                                model.stopNewsNarration()
                            } else {
                                model.readNewsArticle(article)
                            }
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Read original", systemImage: "safari") {
                            guard let url = URL(string: article.url) else { return }
                            NSWorkspace.shared.open(url)
                        }
                        .buttonStyle(.bordered)
                    }

                    if article.sourceDomain.hasSuffix("spiegel.de") {
                        Label(
                            "SPIEGEL+ opens in your normal browser, where your subscription remains signed in. Aitvaras never imports browser cookies.",
                            systemImage: "person.badge.key")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(12)
                            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
                    }

                    if article.supportingSources.count > 1 {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Also covered by").font(.headline)
                            Text(article.supportingSources.joined(separator: " · "))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Divider()
                    Label(
                        "Publisher text is treated as untrusted reference data. It cannot change topics, trigger actions or enter long-term memory.",
                        systemImage: "shield.lefthalf.filled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(26)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        } else {
            ContentUnavailableView(
                "Select a story",
                systemImage: "doc.richtext",
                description: Text("Images, source text and read-aloud controls appear here."))
        }
    }

    private var selectedArticle: NewsArticle? {
        guard let selectedArticleID else { return nil }
        return model.newsArticles.first(where: { $0.id == selectedArticleID })
    }

    private func chooseFirstArticleIfNeeded() {
        if let selectedArticleID,
           model.newsArticles.contains(where: { $0.id == selectedArticleID }) { return }
        selectedArticleID = model.newsArticles.first?.id
    }

    private func presentNewTopicEditor() {
        editor = NewsTopicEditorState(
            topic: NewsTopic(name: "", query: ""), isNew: true)
    }
}

private struct NewsArticleRow: View {
    let article: NewsArticle

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(article.isRead ? Color.clear : Color.accentColor)
                .frame(width: 7, height: 7)
                .padding(.top, 7)
            VStack(alignment: .leading, spacing: 5) {
                Text(article.title)
                    .font(.callout.weight(article.isRead ? .regular : .semibold))
                    .lineLimit(3)
                HStack {
                    Text(article.sourceName).lineLimit(1)
                    Spacer()
                    Text(article.publishedAt, style: .relative)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
    }
}

private struct NewsImagePlaceholder: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.accentColor.opacity(0.25), Color.indigo.opacity(0.16)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing)
            Image(systemName: "newspaper.fill")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
        }
    }
}

private struct SafeNewsImage: View {
    @Environment(AppModel.self) private var model
    let url: URL
    @State private var image: NSImage?
    @State private var finished = false

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                NewsImagePlaceholder()
                if !finished { ProgressView() }
            }
        }
        .task(id: url) {
            finished = false
            image = await model.newsImage(for: url)
            finished = true
        }
    }
}

private struct NewsTopicEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var topic: NewsTopic
    let isNew: Bool

    init(topic: NewsTopic, isNew: Bool) {
        _topic = State(initialValue: topic)
        self.isNew = isNew
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(isNew ? "Add news topic" : "Edit news topic")
                .font(.title2.weight(.semibold))
            Form {
                TextField("Name", text: $topic.name, prompt: Text("Energy transition"))
                TextField("Search terms", text: $topic.query, prompt: Text("energy policy OR grid storage"))
                Picker("Importance", selection: Binding(
                    get: { topic.importanceValue },
                    set: { topic.importance = $0.rawValue })) {
                    ForEach(NewsImportance.allCases, id: \.self) { importance in
                        Text(importance.displayName).tag(importance)
                    }
                }
                Picker("Update interval", selection: Binding(
                    get: { topic.refreshIntervalValue },
                    set: { topic.refreshIntervalMinutes = $0.rawValue })) {
                    ForEach(NewsRefreshInterval.allCases, id: \.self) { interval in
                        Text(interval.displayName).tag(interval)
                    }
                }
                Toggle("Enabled", isOn: $topic.isEnabled)
            }
            Text("Enter a simple subject, or combine focused alternatives with OR and quoted phrases. Search terms are sent to Google News for discovery; direct publisher feeds are filtered locally. Only publishers in Aitvaras's curated source catalogue enter the feed.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) {
                        model.deleteNewsTopic(topic.id)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    if topic.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        topic.query = topic.name
                    }
                    model.saveNewsTopic(topic)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(topic.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

private struct NewsPreferencesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var enabled: Bool
    @State private var time: Date

    init() {
        let preferences = AppModel.shared.newsMorningPreferences
        _enabled = State(initialValue: preferences.isEnabled)
        let value = Calendar.current.date(
            bySettingHour: preferences.hour,
            minute: preferences.minute,
            second: 0,
            of: .now) ?? .now
        _time = State(initialValue: value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("News settings").font(.title2.weight(.semibold))
            GroupBox("Morning offer") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Ask once in the morning", isOn: $enabled)
                    DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                        .disabled(!enabled)
                    Text("This is the only proactive news interruption. New stories never trigger alerts by themselves.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
            }
            GroupBox("Sources") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Source-first ranking")
                        .font(.headline)
                    Text("Wire services, established publications and primary research or company sources rank above aggregators. Cross-source coverage receives a small boost.")
                        .foregroundStyle(.secondary)
                    Text("Included direct feeds: DER SPIEGEL, Tagesschau, BBC, DW, Nature, Ars Technica, OpenAI, DeepMind, Hugging Face and GitHub, plus Claude Code and Codex releases and selected practical developer sources.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("X/Twitter is excluded for now: without a dedicated authenticated integration it is too noisy and too weakly sourced for this feed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    let components = Calendar.current.dateComponents([.hour, .minute], from: time)
                    model.setNewsMorningPreferences(NewsMorningPreferences(
                        isEnabled: enabled,
                        hour: components.hour ?? 8,
                        minute: components.minute ?? 0))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 600)
    }
}
