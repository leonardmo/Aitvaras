import Foundation
import AitvarasAgents
import AitvarasStore

struct SettingsSearchResult: Identifiable {
    let id: String
    let title: String
    let context: String?
    let icon: String
    let destination: SettingsDestination
    let settingID: String?
    let keywords: String

    static func results(for query: String, projects: [WorkspaceProject], currentProject: UUID?) -> [Self] {
        let phrase = searchableText(query)
        let words = phrase.split(separator: " ")
        guard !words.isEmpty else { return [] }
        var candidates = SettingsPage.allCases.map { page in
            Self(id: "page." + page.rawValue, title: page.title, context: nil, icon: page.icon,
                 destination: .page(page), settingID: nil, keywords: pageKeywords[page] ?? "")
        }
        for setting in SettingsRegistry.entries where setting.scope == .profile {
            guard let page = SettingsPage(rawValue: setting.destination) else { continue }
            candidates.append(Self(id: setting.id, title: setting.title, context: page.title, icon: page.icon,
                                   destination: .page(page), settingID: setting.id,
                                   keywords: [setting.id, setting.hint ?? "", settingKeywords[setting.id] ?? ""].joined(separator: " ")))
        }
        for project in projects {
            let projectWords = searchableText(project.title)
            guard project.isVisible || (!projectWords.isEmpty &&
                (phrase.contains(projectWords) || words.allSatisfy { projectWords.contains($0) })) else { continue }
            candidates.append(Self(id: "project." + project.id.uuidString, title: project.title, context: "Project",
                                   icon: "folder", destination: .project(project.id, section: .general),
                                   settingID: nil, keywords: "project"))
            for setting in SettingsRegistry.entries where setting.scope == .project {
                guard let section = ProjectSettingsSection(rawValue: setting.destination) else { continue }
                candidates.append(Self(id: project.id.uuidString + "." + setting.id, title: setting.title,
                                       context: project.title + " · " + section.title, icon: "folder",
                                       destination: .project(project.id, section: section), settingID: setting.id,
                                       keywords: [setting.id, setting.hint ?? "", settingKeywords[setting.id] ?? ""].joined(separator: " ")))
            }
        }
        return candidates.compactMap { result -> (result: Self, score: Int, preferredProject: Bool)? in
            let title = searchableText(result.title)
            let keywords = searchableText(result.keywords)
            let context = searchableText(result.context ?? "")
            let combined = title + " " + context + " " + keywords
            guard words.allSatisfy({ combined.contains($0) }) else { return nil }
            let score: Int
            if title == phrase { score = 0 }
            else if title.hasPrefix(phrase) { score = 1 }
            else if title.contains(phrase) || words.allSatisfy({ title.contains($0) }) { score = 2 }
            else if keywords.contains(phrase) { score = 3 }
            else { score = 4 }
            let preferredProject: Bool
            if case .project(let id, _) = result.destination { preferredProject = id == currentProject }
            else { preferredProject = false }
            return (result, score, preferredProject)
        }.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score < rhs.score }
            if lhs.preferredProject != rhs.preferredProject { return lhs.preferredProject }
            if lhs.result.title != rhs.result.title {
                return lhs.result.title.localizedStandardCompare(rhs.result.title) == .orderedAscending
            }
            return (lhs.result.context ?? "").localizedStandardCompare(rhs.result.context ?? "") == .orderedAscending
        }.map(\.result)
    }

    private static func searchableText(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: " ")
    }

    private static let pageKeywords: [SettingsPage: String] = [
        .avatar: "appearance theme floating overlay accessibility",
        .providers: "Add provider Claude Codex Local Ollama accounts login sign in",
        .access: "privacy macOS system permissions"
    ]

    private static let settingKeywords = [
        "appearance.mode": "theme light dark system",
        "appearance.alwaysAnimate": "animation animations reduced motion accessibility",
        "companion.presentation": "dragon avatar minimal overlay",
        "project.folders": "directory directories workspace root"
    ]
}
