import SwiftUI
import AppKit
import AitvarasCore
import AitvarasStore

enum SidebarItem: String, CaseIterable, Identifiable {
    // Stable legacy values also remain valid stored routes.
    case today = "Today", chat = "Chat", voice = "Voice", news = "News"
    case memory = "Memory", knowledge = "Knowledge", activity = "Activity"
    case shortcuts = "Shortcuts", connectors = "Connections", setup = "Setup"
    case capture = "Capture", library = "Library"
    static let primary: [SidebarItem] = [.today, .chat, .capture, .library, .activity, .setup]
    var id: String { rawValue }
    var title: String {
        switch self {
        case .today: "Home"
        case .activity: "History"
        case .setup: "Settings"
        default: rawValue
        }
    }
    /// One hue per destination, from the shared activity palette, so the rail
    /// reads by colour as well as by glyph.
    var tint: Color {
        switch primaryRoute {
        case .chat: ActivityGlassPalette.violet
        case .capture: ActivityGlassPalette.recording
        case .library: .cyan
        case .activity: ActivityGlassPalette.ember
        case .setup: ActivityGlassPalette.slate
        default: ActivityGlassPalette.slate
        }
    }

    var primaryRoute: SidebarItem {
        switch self {
        case .voice: .chat
        case .news: .today
        case .memory, .knowledge: .library
        case .shortcuts, .connectors: .setup
        default: self
        }
    }
    var icon: String {
        switch self {
        case .today: "house"
        case .chat: "bubble.left.and.text.bubble.right"
        case .capture: "record.circle"
        case .library, .knowledge: "books.vertical"
        case .activity: "clock.arrow.circlepath"
        case .setup: "gearshape"
        case .voice: "waveform"
        case .news: "newspaper"
        case .memory: "brain"
        case .shortcuts: "bolt.badge.clock"
        case .connectors: "app.connected.to.app.below.fill"
        }
    }
}

struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarItem = Self.initialSelection
    @State private var showArchivedNewsNote = CommandLine.arguments.contains("--open-news")
    @State private var settingsBackgroundRequested = CommandLine.arguments.contains("--open-background-review")
    @State private var activityDockPlacement = ActivityDockPlacement.load()
    @State private var sidebarVisible = !CommandLine.arguments.contains("--hide-sidebar-fixture")
    private var resolvedDockPlacement: ActivityDockPlacement {
        activityDockPlacement.resolved(
            sidebarVisible: sidebarVisible && chatSelected)
    }
    private var chatSelected: Bool { selection.primaryRoute == .chat }

    @ViewBuilder private func layoutProbe(_ key: String) -> some View {
        if CommandLine.arguments.contains("--sidebar-window-check"), AitvarasPaths.isIsolated {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { SidebarLayoutProbe.frames[key] = geometry.frame(in: .global) }
                    .onChange(of: geometry.frame(in: .global)) { SidebarLayoutProbe.frames[key] = geometry.frame(in: .global) }
            }
        }
    }

    /// Glyph only; the name is the tooltip. The selected destination keeps its
    /// own hue, so the rail stays readable at this width.
    private func sidebarRow(_ item: SidebarItem) -> some View {
        let selected = selection.primaryRoute == item
        return Button { selection = item } label: {
            Image(systemName: item.icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(selected ? item.tint : Color.secondary)
                .frame(width: 36, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(item.tint.opacity(selected ? 0.18 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.title)
        .accessibilityLabel(item.title)
        .accessibilityIdentifier(item.icon)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .overlay(alignment: .topTrailing) {
            if item == .chat, model.chatModel?.needsPerson == true {
                Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                    .allowsHitTesting(false).accessibilityElement(children: .ignore)
                    .accessibilityLabel("Chat needs you").accessibilityIdentifier("chat.needsYou")
            }
        }
        .background { layoutProbe("button-\(item.rawValue)") }
    }

    private static var initialSelection: SidebarItem {
        let flags: [(String, SidebarItem)] = [("--open-setup", .setup), ("--open-news", .news), ("--open-shortcuts", .shortcuts), ("--open-chat", .chat), ("--open-capture", .capture), ("--open-history", .activity)]
        if let route = flags.first(where: { CommandLine.arguments.contains($0.0) }) { return route.1 }
        return AitvarasPreferences.current.string(forKey: "navigation.lastSelection").flatMap(SidebarItem.init(rawValue:)) ?? .today
    }
    var body: some View {
        // Keep the rail outside NSSplitView's retained divider allocation.
        // Otherwise a previous Chat width can survive in icon-only sections.
        HStack(spacing: 0) {
            if sidebarVisible {
                HStack(spacing: 0) {
                    VStack(spacing: 3) {
                        ForEach(SidebarItem.primary) { item in sidebarRow(item) }
                        Spacer(minLength: 0)
                        AppearanceQuickControl().padding(.bottom, 4)
                    }
                    .padding(.vertical, 8).padding(.horizontal, 7)
                    .frame(width: 50)
                    .background { layoutProbe("icons") }
                    // In Chat the workspace fills the rest of this same sidebar;
                    // elsewhere the rail stays narrow and the panel gets the width.
                    if chatSelected {
                        Divider()
                        WorkspaceRailView().frame(width: 195).frame(maxHeight: .infinity)
                            .background { layoutProbe("projects") }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .frame(width: chatSelected ? 246 : 50)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if resolvedDockPlacement == .sidebarFooter {
                        ActivityDockView(placement: $activityDockPlacement, presentation: .sidebarFooter)
                            .padding(8)
                    }
                }
                // Constrain the complete column, including its footer. An
                // inset's intrinsic width must not expand the navigation rail.
                .frame(width: chatSelected ? 246 : 50, alignment: .leading)
                .background { layoutProbe("sidebar") }
                Divider()
            }
            VStack(spacing: 0) {
                if showArchivedNewsNote || selection == .news {
                    HStack {
                        Label("News is archived. Saved briefings remain available; it is no longer a primary workspace.", systemImage: "archivebox")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Dismiss") { showArchivedNewsNote = false; selection = .today }.controlSize(.small)
                    }.padding(12)
                    Divider()
                }
                destination.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // The dock belongs to the detail column: a window-level inset lets
            // column content keep its full height and run underneath the bar.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                switch resolvedDockPlacement {
                case .bottomDock:
                    ActivityDockView(placement: $activityDockPlacement, presentation: .bottomDock)
                        .padding(.horizontal, 12).padding(.bottom, 12).padding(.top, 10)
                case .minimized:
                    HStack {
                        Spacer(minLength: 0)
                        ActivityDockView(placement: $activityDockPlacement, presentation: .minimized)
                            .frame(maxWidth: 360)
                    }
                    .padding(.horizontal, 12).padding(.bottom, 12).padding(.top, 10)
                case .sidebarFooter:
                    EmptyView()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { layoutProbe("root") }
        .navigationTitle(selection.primaryRoute.title)
        .toolbar {
            // Window-level, never inside the collapsible sidebar. It remains
            // available in every destination and when the rail is hidden.
            ToolbarItem(id: "aitvaras.sidebarToggle", placement: .navigation) {
                Button {
                    sidebarVisible.toggle()
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .help(sidebarVisible ? "Hide Sidebar" : "Show Sidebar")
                .accessibilityLabel(sidebarVisible ? "Hide Sidebar" : "Show Sidebar")
                .keyboardShortcut("s", modifiers: [.command, .control])
            }
        }
        .containerBackground(for: .window) {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                LinearGradient(colors: [Color.accentColor.opacity(0.06), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .onChange(of: selection) { AitvarasPreferences.current.set(selection.rawValue, forKey: "navigation.lastSelection") }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("aitvaras.sidebarCheckRoute"))) { notification in
            guard AitvarasPaths.isIsolated, ProcessInfo.processInfo.environment["AITVARAS_UI_TEST_MODE"] == "1",
                  CommandLine.arguments.contains("--sidebar-window-check"),
                  let raw = notification.object as? String, let item = SidebarItem(rawValue: raw) else { return }
            selection = item
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("aitvaras.sidebarCheckDock"))) { notification in
            guard AitvarasPaths.isIsolated, ProcessInfo.processInfo.environment["AITVARAS_UI_TEST_MODE"] == "1",
                  CommandLine.arguments.contains("--sidebar-window-check"),
                  let placement = notification.object as? ActivityDockPlacement else { return }
            activityDockPlacement = placement
        }
        .onChange(of: activityDockPlacement) { activityDockPlacement.save() }
        .alert(item: Binding(get: { model.presentedError }, set: { model.presentedError = $0 })) { error in
            Alert(title: Text(error.title), message: Text(error.message), dismissButton: .default(Text("OK")))
        }
        .onReceive(NotificationCenter.default.publisher(for: .aitvarasOpenNews)) { _ in
            selection = .today
            showArchivedNewsNote = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .aitvarasOpenActivity)) { _ in selection = .activity }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("aitvaras.openWorkspaceChat"))) { _ in
            selection = .chat
        }
        .onReceive(NotificationCenter.default.publisher(for: .aitvarasOpenBackgroundReview)) { _ in
            settingsBackgroundRequested = true
            selection = .setup
        }
    }
    @ViewBuilder private var destination: some View {
        switch selection {
        case .today, .news: TodayView(selection: $selection)
        case .chat, .voice: ChatDetailView()
        case .capture: CaptureWorkspaceView()
        case .library, .memory, .knowledge: LibraryWorkspaceView(initialKnowledge: selection == .knowledge).id(selection)
        case .activity: ActivityView()
        case .setup, .connectors, .shortcuts:
            SettingsWorkspaceView(initialRoute: selection, initialBackground: settingsBackgroundRequested)
                .id("\(selection.rawValue).\(settingsBackgroundRequested)")
        }
    }
}

private struct LibraryWorkspaceView: View {
    @State private var knowledge: Bool
    init(initialKnowledge: Bool) { _knowledge = State(initialValue: initialKnowledge) }
    var body: some View {
        VStack(spacing: 0) {
            Picker("Library", selection: $knowledge) {
                Text("Memory").tag(false)
                Text("Knowledge sources").tag(true)
            }.pickerStyle(.segmented).padding().frame(maxWidth: 400)
            if knowledge { KnowledgeView() } else { MemoryView() }
        }.navigationTitle("Library")
    }
}

struct SettingsWorkspaceView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: String
    init(initialRoute: SidebarItem, initialBackground: Bool = false) {
        _tab = State(initialValue: initialBackground ? "background" : initialRoute == .connectors ? "connections" : initialRoute == .shortcuts ? "routines" : AitvarasPreferences.current.string(forKey: "settings.lastPane") ?? "setup")
    }
    var body: some View {
        TabView(selection: $tab) {
            if let chat = model.chatModel {
                AgentProviderSettingsView(chat: chat).tabItem { Label("Providers", systemImage: "cpu") }.tag("providers").accessibilityIdentifier("settings.providers")
            }
            OnboardingView(openProviders: { tab = "providers" }).tabItem { Label("Setup", systemImage: "checklist") }.tag("setup")
            ConnectorsView().tabItem { Label("Connections", systemImage: "point.3.connected.trianglepath.dotted") }.tag("connections")
            CommandRoutinesView(model: model).tabItem { Label("Routines", systemImage: "command") }.tag("routines")
            BackgroundReviewView().tabItem { Label("Automatic Work", systemImage: "clock") }.tag("background")
        }.navigationTitle("Settings")
        .onChange(of: tab) { AitvarasPreferences.current.set(tab, forKey: "settings.lastPane") }
    }
}

private struct CaptureWorkspaceView: View {
    @Environment(AppModel.self) private var model
    @State private var records: [CaptureRecord] = []
    var body: some View {
        List {
            Section {
                Text("Transcripts and recognized screen text stay on this Mac. Source audio is discarded by default, or retained only when you explicitly choose it before capture. Video is never saved.").foregroundStyle(.secondary)
                if let capture = model.capture, capture.isStarting || capture.isActive {
                    Label(capture.sleepProtectionSummary, systemImage: "moon.zzz")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let capture = model.capture, model.captureActive {
                    Label(capture.isActive ? "Capture running · \(capture.lineCount) transcript lines" : capture.isFinishing ? "Finalizing capture · transcript checkpoint retained" : "Capture needs to be saved", systemImage: "record.circle.fill")
                    if capture.retainsAudio {
                        Label("Source audio is being saved locally", systemImage: "externaldrive.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if let warning = capture.durabilityWarning { Text(warning).foregroundStyle(.orange) }
                }
                Button(model.capture?.isFinishing == true ? "Finalizing…" : model.captureActive ? "Stop and save capture" : "Start capture…") { model.toggleCapture() }
                    .disabled(model.capture == nil || model.capture?.isFinishing == true || model.capture?.isStarting == true)
            }
            if let capture = model.capture, model.captureActive {
                Section("Live transcript") {
                    Text(capture.scopeLabel).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Microphone").font(.caption)
                            ProgressView(value: Double(capture.microphoneLevel))
                        }
                        VStack(alignment: .leading) {
                            Text("System audio").font(.caption)
                            ProgressView(value: Double(capture.systemAudioLevel))
                        }
                    }
                    Text("Input levels show audio activity, not transcription accuracy. Only selected sources receive audio.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !capture.recentCaptionLines.isEmpty {
                        Text(capture.recentCaptionLines.joined(separator: "\n\n"))
                            .font(.callout).textSelection(.enabled)
                    }
                    if !capture.liveCaptionIsFinal, !capture.liveCaption.isEmpty {
                        Text("\(capture.liveCaptionSource) · provisional").font(.caption).foregroundStyle(.secondary)
                        Text(capture.liveCaption).foregroundStyle(.secondary)
                    } else if capture.recentCaptionLines.isEmpty {
                        Text("Waiting for recognized speech…").foregroundStyle(.secondary)
                    }
                    if !capture.lastScreenText.isEmpty {
                        DisclosureGroup("Last recognized screen text") {
                            Text(capture.lastScreenText).font(.caption).textSelection(.enabled)
                        }
                    }
                    Text("Subtitles can also be shown inside the companion. Hiding that panel does not stop capture.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Saved captures") {
                if records.isEmpty { Text("No saved captures yet.").foregroundStyle(.secondary) }
                ForEach(records) { record in
                    Button { CaptureWindows.shared.showResult(record: record, model: model) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(record.title.isEmpty ? "Untitled capture" : record.title)
                            Text(record.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            if record.summaryPending { Text("Summary pending; transcript saved").font(.caption).foregroundStyle(.orange) }
                        }
                    }.buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("Capture")
        .task { reload() }
        .onReceive(NotificationCenter.default.publisher(for: .aitvarasCaptureRecordsChanged).receive(on: RunLoop.main)) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .aitvarasActivityChanged)) { _ in reload() }
        .toolbar { Button("Refresh", systemImage: "arrow.clockwise") { reload() } }
    }
    private func reload() {
        do { records = try model.stores?.captureRecords(limit: 100) ?? [] }
        catch { model.presentError(title: "Captures could not be loaded", error: error) }
    }
}

extension Notification.Name {
    static let aitvarasOpenNews = Notification.Name("aitvaras.openNews")
    static let aitvarasOpenActivity = Notification.Name("aitvaras.openActivity")
    static let aitvarasOpenBackgroundReview = Notification.Name("aitvaras.openBackgroundReview")
}
