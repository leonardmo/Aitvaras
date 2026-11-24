import SwiftUI
import AitvarasCore
import AitvarasStore

enum SettingsPage: String, CaseIterable, Identifiable {
    case overview, providers, models, cloud, connections, routines, background, avatar, voice, capture, memory, access, usage

    var id: String { rawValue }
    var setupPage: SetupPage? { SetupPage(rawValue: rawValue) }
    var title: String {
        switch self {
        case .overview: "Getting started"
        case .providers: "Providers"
        case .connections: "Connections"
        case .routines: "Routines"
        case .background: "Automatic work"
        case .avatar: "Companion"
        case .capture: "Capture"
        case .memory: "Memory"
        case .access: "Permissions"
        case .usage: "Usage"
        case .cloud: "Cloud & privacy"
        case .models, .voice: setupPage?.title ?? rawValue.capitalized
        }
    }
    var icon: String {
        switch self {
        case .providers: "person.2"
        case .models: "memorychip"
        case .connections: "point.3.connected.trianglepath.dotted"
        case .routines: "command"
        case .background: "clock"
        default: setupPage?.icon ?? "gearshape"
        }
    }
}

enum ProjectSettingsSection: String, Hashable {
    case general, folders, agent, codex, gateway, servers

    var title: String {
        switch self {
        case .general: "General"
        case .folders: "Folders"
        case .agent: "Agent setup"
        case .codex: "Codex link"
        case .gateway: "Aitvaras tools"
        case .servers: "MCP servers"
        }
    }
}

enum SettingsDestination: Equatable {
    case page(SettingsPage)
    case project(UUID, section: ProjectSettingsSection)
}

@MainActor @Observable final class SettingsNavigation {
    struct Request: Equatable {
        let id = UUID()
        let destination: SettingsDestination
        let settingID: String?
    }

    static let shared = SettingsNavigation()
    private(set) var request: Request?
    struct Highlight: Equatable {
        let id = UUID()
        let settingID: String
    }

    private(set) var highlight: Highlight?
    var highlightedID: String? { highlight?.settingID }
    @ObservationIgnored private var presentedRequestID: UUID?

    static func open(_ destination: SettingsDestination, settingID: String? = nil) {
        shared.request = .init(destination: destination, settingID: settingID)
    }

    func claimPresentation(_ id: UUID) -> Bool {
        guard presentedRequestID != id else { return false }
        presentedRequestID = id
        return true
    }

    func highlightSetting(_ id: String?) { highlight = id.map { Highlight(settingID: $0) } }
}

extension View {
    func settingsAnchor(_ id: String) -> some View {
        modifier(SettingsAnchor(id: id))
    }
}

private struct SettingsAnchor: ViewModifier {
    let id: String

    func body(content: Content) -> some View {
        content
            .padding(.vertical, 2)
            .background {
                if SettingsNavigation.shared.highlightedID == id {
                    RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.14))
                }
            }
            .id(id)
            .accessibilityIdentifier("settings.option.\(id)")
    }
}

struct SettingsWorkspaceView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var destination: SettingsDestination
    @State private var seenRequest: UUID?
    @State private var showHiddenProjects = false
    @State private var projectHasUnsavedChanges = false
    @State private var pendingSelection: (destination: SettingsDestination, settingID: String?)?
    @State private var navigationRevision = UUID()
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

    init(initialDestination: SettingsDestination? = nil) {
        let lastPane = AitvarasPreferences.current.string(forKey: "settings.lastPane").flatMap(SettingsPage.init(rawValue:)) ?? .overview
        _destination = State(initialValue: initialDestination ?? .page(lastPane))
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar

            Divider()

            VStack(spacing: 0) {
                HStack {
                    Label(destinationTitle, systemImage: destinationIcon)
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button("Ask Aitvaras", systemImage: "bubble.left", action: askAitvaras)
                        .labelStyle(.titleAndIcon)
                        .buttonStyle(.bordered)
                        .help("Open a chat draft about these settings")
                        .disabled(!canAskAitvaras)
                        .accessibilityIdentifier("settings.askAitvaras")
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 15)
                Divider()
                settingsDetail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(item: Binding(get: { model.editingSettingsProposal }, set: { model.editingSettingsProposal = $0 })) { proposal in
            SettingsProposalValueEditor(proposal: proposal).environment(model)
        }
        .navigationTitle("Settings")
        .onChange(of: SettingsNavigation.shared.request, initial: true) { _, request in
            guard let request, seenRequest != request.id else { return }
            seenRequest = request.id
            select(request.destination, settingID: request.settingID)
        }
        .confirmationDialog("Discard unsaved project edits?", isPresented: Binding(
            get: { pendingSelection != nil },
            set: { if !$0 { pendingSelection = nil } }
        ), titleVisibility: .visible) {
            Button("Discard edits", role: .destructive) {
                guard let next = pendingSelection else { return }
                pendingSelection = nil
                projectHasUnsavedChanges = false
                select(next.destination, settingID: next.settingID)
            }
            Button("Keep editing", role: .cancel) { pendingSelection = nil }
        }
        .task { model.refreshWorkspaces() }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            searchField.padding(8)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        sidebarNavigation
                    } else {
                        let results = searchResults
                        if results.isEmpty {
                            Text("No matching settings")
                                .font(.callout).foregroundStyle(.secondary)
                                .padding(.horizontal, 7).padding(.vertical, 12)
                        } else {
                            ForEach(results, content: searchRow)
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(.bar)
        .frame(width: 190)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.sidebar")
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Button { searchFocused = true } label: {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("f", modifiers: .command)
            .accessibilityLabel("Focus Settings search")
            TextField("Search settings", text: $searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .accessibilityIdentifier("settings.search")
                .onSubmit { if let first = searchResults.first { openResult(first) } }
                .onKeyPress(.escape) {
                    guard !searchText.isEmpty else { return .ignored }
                    searchText = ""
                    return .handled
                }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear Settings search")
                .accessibilityIdentifier("settings.search.clear")
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 27)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    private var searchResults: [SettingsSearchResult] {
        SettingsSearchResult.results(for: searchText, projects: model.workspaceProjects, currentProject: activeProjectID)
    }

    private func openResult(_ result: SettingsSearchResult) {
        searchFocused = false
        select(result.destination, settingID: result.settingID)
    }

    private func searchRow(_ result: SettingsSearchResult) -> some View {
        Button { openResult(result) } label: {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: result.icon).foregroundStyle(.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.title).lineLimit(2)
                    if let context = result.context {
                        Text(context).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            if destination == result.destination
                && SettingsNavigation.shared.highlightedID == result.settingID {
                RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.15))
            }
        }
        .accessibilityIdentifier("settings.search.result.\(result.id)")
    }

    @ViewBuilder private var sidebarNavigation: some View {
        pageRow(.overview)
        navigationGroup("AI", pages: [.providers, .models, .cloud])
        navigationGroup("Integrations", pages: [.connections, .routines, .background])
        navigationGroup("You", pages: [.avatar, .voice, .capture, .memory])
        navigationGroup("System", pages: [.access, .usage])
        if !model.workspaceProjects.isEmpty {
            sidebarHeading("Projects")
            ForEach(model.workspaceProjects.filter(\.isVisible)) { project in projectRow(project) }
            let hidden = model.workspaceProjects.filter { !$0.isVisible }
            if !hidden.isEmpty {
                Button {
                    showHiddenProjects.toggle()
                } label: {
                    Label("Hidden projects", systemImage: showHiddenProjects ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.plain)
                .accessibilityValue(showHiddenProjects ? "Expanded" : "Collapsed")
                .accessibilityIdentifier("settings.projects.hidden")
                if showHiddenProjects {
                    ForEach(hidden) { project in projectRow(project) }
                }
            }
        }
    }

    private func navigationGroup(_ name: String, pages: [SettingsPage]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sidebarHeading(name)
            ForEach(pages) { pageRow($0) }
        }
    }

    private func sidebarHeading(_ title: String) -> some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 7).padding(.top, 8)
            .accessibilityAddTraits(.isHeader)
    }

    private func pageRow(_ page: SettingsPage) -> some View {
        Button { select(.page(page)) } label: {
            Label(page.title, systemImage: page.icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 7).padding(.vertical, 5)
        .background(destination == .page(page) ? Color.accentColor.opacity(0.15) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .accessibilityAddTraits(destination == .page(page) ? [.isSelected] : [])
        .accessibilityIdentifier(page == .providers ? "settings.providers" : "settings.pane.\(page.rawValue)")
    }

    private func projectRow(_ project: WorkspaceProject) -> some View {
        Button { select(.project(project.id, section: .general)) } label: {
            Label(project.title, systemImage: project.isVisible ? "folder" : "folder.badge.minus")
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 7).padding(.vertical, 5)
        .background(activeProjectID == project.id ? Color.accentColor.opacity(0.15) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .accessibilityAddTraits(activeProjectID == project.id ? [.isSelected] : [])
        .accessibilityIdentifier("settings.project.\(project.id)")
    }

    private var activeProjectID: UUID? {
        if case .project(let id, _) = destination { return id }
        return nil
    }

    private var destinationTitle: String {
        switch destination {
        case .page(let page): page.title
        case .project(let id, _): model.workspaceProjects.first { $0.id == id }?.title ?? "Project settings"
        }
    }

    private var destinationIcon: String {
        switch destination {
        case .page(let page): page.icon
        case .project: "folder"
        }
    }

    private func select(_ value: SettingsDestination, settingID: String? = nil) {
        if projectHasUnsavedChanges {
            if case .project(let id, _) = value, id == activeProjectID {
                // Moving between sections leaves the shared project form in place.
            } else {
                pendingSelection = (value, settingID)
                return
            }
        }
        SettingsNavigation.shared.highlightSetting(settingID)
        navigationRevision = UUID()
        destination = value
        switch value {
        case .page(let page): AitvarasPreferences.current.set(page.rawValue, forKey: "settings.lastPane")
        case .project(let id, _):
            if model.workspaceProjects.first(where: { $0.id == id })?.isVisible == false { showHiddenProjects = true }
        }
    }

    @ViewBuilder private var settingsDetail: some View {
        switch destination {
        case .page(.providers):
            if let chat = model.chatModel {
                AgentProviderSettingsView(chat: chat).accessibilityIdentifier("settings.providers.page")
            }
        case .page(.connections):
            ConnectorsView(handlesGatewayTokenLinks: true)
        case .page(.routines):
            CommandRoutinesView(model: model)
        case .page(.background):
            BackgroundReviewView()
        case .page(let page):
            if let setupPage = page.setupPage {
                OnboardingView(initialPage: setupPage, openProviders: { select(.page(.providers)) },
                               openPage: { page in
                    if let destination = SettingsPage(rawValue: page.rawValue) { select(.page(destination)) }
                })
                .id(setupPage)
            }
        case .project(let id, let section):
            WorkspaceBoundaryReviewView(projectID: id, section: section, embedded: true, navigationRevision: navigationRevision) { changed in
                projectHasUnsavedChanges = changed
            }
            .id(id)
        }
    }

    private var canAskAitvaras: Bool {
        guard let chat = model.chatModel, !chat.creatingChat, !model.isWorkspaceSelectionBusy else { return false }
        if let id = activeProjectID { return model.workspaceProjects.contains { $0.id == id && $0.isVisible } }
        return true
    }

    private func askAitvaras() {
        guard canAskAitvaras else { return }
        model.startNewAgentChat(projectID: activeProjectID)
        let setting = SettingsNavigation.shared.highlightedID.map { " (setting ID: \($0))" } ?? ""
        model.chatModel?.editDraft("Help me with \(destinationTitle) settings\(setting). ")
        openWindow(id: "main")
    }
}
