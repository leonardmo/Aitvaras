import SwiftUI
import AitvarasCore

/// RAG index management + retrieval preview (D11).
struct KnowledgeView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var results: [RetrievedChunk] = []
    @State private var searching = false
    @State private var showFolderPicker = false

    var body: some View {
        Form {
            if let coordinator = model.integrations {
                Section("Sources") {
                    if coordinator.ragSourceConfigs.isEmpty {
                        Text("No folders indexed yet. Add your notes or code folders — Aitvaras grounds answers in them.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(coordinator.ragSourceConfigs) { source in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.name)
                                Text(source.path)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Remove", role: .destructive) {
                                coordinator.removeRAGSource(id: source.id)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    Button("Add Folder…") { showFolderPicker = true }
                        .fileImporter(isPresented: $showFolderPicker,
                                      allowedContentTypes: [.folder]) { result in
                            if case .success(let url) = result {
                                coordinator.addRAGSource(url: url)
                            }
                        }
                }

                Section("Index") {
                    LabeledContent("Documents", value: "\(coordinator.indexStats.documents)")
                    LabeledContent("Chunks", value: "\(coordinator.indexStats.chunks)")
                    LabeledContent("Embedded", value: "\(coordinator.indexStats.embedded)")
                    HStack {
                        Button(coordinator.isIndexing ? "Indexing…" : "Reindex now") {
                            coordinator.reindex()
                        }
                        .disabled(coordinator.isIndexing)
                        if coordinator.isIndexing {
                            Text(coordinator.indexProgressText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("Embeddings need Ollama running (`ollama serve`) with nomic-embed-text. Without it, keyword search still works; embeddings backfill on the next reindex.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Test retrieval") {
                    HStack {
                        TextField("What would Aitvaras find for…", text: $query)
                            .onSubmit(search)
                        Button("Search") { search() }
                            .disabled(query.isEmpty || searching)
                    }
                    ForEach(Array(results.enumerated()), id: \.offset) { _, chunk in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(chunk.origin)
                                .font(.caption.monospaced())
                                .foregroundStyle(.teal)
                            Text(chunk.text)
                                .font(.callout)
                                .lineLimit(6)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Knowledge")
        .task { model.integrations?.refreshIndexStats() }
    }

    private func search() {
        guard let retriever = model.integrations?.retriever else { return }
        searching = true
        let q = query
        Task {
            results = (try? await retriever.retrieve(query: q, limit: 8)) ?? []
            searching = false
        }
    }
}
