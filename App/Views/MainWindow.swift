import SwiftUI
import AppKit

enum SidebarItem: String, CaseIterable, Identifiable {
    case chat = "Chat"
    case voice = "Voice"
    case memory = "Memory"
    case knowledge = "Knowledge"
    case activity = "Activity"
    case connectors = "Connections"
    case setup = "Setup"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .chat: "bubble.left.and.text.bubble.right"
        case .voice: "waveform"
        case .memory: "brain"
        case .knowledge: "books.vertical"
        case .activity: "clock.arrow.circlepath"
        case .connectors: "app.connected.to.app.below.fill"
        case .setup: "checklist"
        }
    }
}

struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarItem = .chat

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.rawValue, systemImage: item.icon).tag(item)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(.clear)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            .safeAreaInset(edge: .bottom) {
                statusFooter
            }
        } detail: {
            switch selection {
            case .chat: ChatView()
            case .voice: VoiceHistoryView()
            case .memory: MemoryView()
            case .knowledge: KnowledgeView()
            case .activity: ActivityView()
            case .connectors: ConnectorsView()
            case .setup: OnboardingView()
            }
        }
        .containerBackground(for: .window) {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                LinearGradient(
                    colors: [
                        Color.accentColor.opacity(0.08),
                        .clear,
                        Color.indigo.opacity(0.035)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .alert("Aitvaras could not start", isPresented: .constant(model.bootError != nil)) {
            Button("OK") {}
        } message: {
            Text(model.bootError ?? "")
        }
    }

    private var statusFooter: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.engineName == "none" ? .red : .green)
                .frame(width: 7, height: 7)
            Text(engineLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .glassEffect(.clear.tint(Color.accentColor.opacity(0.06)), in: Capsule())
        .padding(8)
    }

    private var engineLabel: String {
        switch model.engineName {
        case "mlx": "MLX · Qwen3-30B on-device"
        case "ollama": "Ollama · fallback"
        case "none": "No engine available"
        default: model.engineName
        }
    }
}
