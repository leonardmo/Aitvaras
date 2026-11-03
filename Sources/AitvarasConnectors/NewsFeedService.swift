import Foundation
import AitvarasCore
import AitvarasStore

public enum NewsSourceTier: String, Sendable {
    case primary
    case wire
    case premium
    case specialist
}

public struct NewsSourceAssessment: Sendable, Equatable {
    public var tier: NewsSourceTier
    public var score: Double
    public var preferred: Bool

    public init(tier: NewsSourceTier, score: Double, preferred: Bool = false) {
        self.tier = tier
        self.score = score
        self.preferred = preferred
    }
}

/// Deliberately small and explicit. Google News supplies discovery, but an
/// item enters the feed only when its publisher matches this catalogue.
/// Primary sources are valuable for announcements; established reporting is
/// preferred for interpretation. SPIEGEL receives a small preference boost
/// because the intended user can open SPIEGEL+ links in their signed-in browser.
public enum NewsSourceCatalog {
    private struct Rule {
        var domains: [String]
        var tier: NewsSourceTier
        var score: Double
        var preferred: Bool = false
    }

    private static let rules: [Rule] = [
        Rule(domains: ["reuters.com", "apnews.com"], tier: .wire, score: 1.00),
        Rule(domains: ["spiegel.de"], tier: .premium, score: 0.98, preferred: true),
        Rule(domains: ["tagesschau.de", "bbc.com", "bbc.co.uk", "dw.com"], tier: .premium, score: 0.96),
        Rule(domains: ["ft.com", "economist.com", "bloomberg.com"], tier: .premium, score: 0.96),
        Rule(domains: ["nytimes.com", "washingtonpost.com", "theguardian.com", "npr.org"], tier: .premium, score: 0.94),
        Rule(domains: ["zeit.de", "faz.net", "sueddeutsche.de", "handelsblatt.com", "politico.eu", "politico.com"], tier: .premium, score: 0.94),
        Rule(domains: ["nature.com", "science.org", "cell.com", "nejm.org", "thelancet.com", "arxiv.org"], tier: .primary, score: 0.97),
        Rule(domains: ["openai.com", "anthropic.com", "deepmind.google", "ai.meta.com", "microsoft.com", "apple.com", "nvidia.com"], tier: .primary, score: 0.95),
        Rule(domains: ["github.blog", "huggingface.co", "developers.googleblog.com"], tier: .primary, score: 0.94),
        Rule(domains: ["technologyreview.com", "arstechnica.com", "wired.com"], tier: .specialist, score: 0.93),
        Rule(domains: ["simonwillison.net", "oneusefulthing.org"], tier: .specialist, score: 0.92),
        Rule(domains: ["theverge.com", "techcrunch.com"], tier: .specialist, score: 0.88),
        Rule(domains: ["bundesregierung.de", "europa.eu", "ec.europa.eu", "who.int", "un.org", "nasa.gov"], tier: .primary, score: 0.96)
    ]

    public static func assessment(forDomain rawDomain: String) -> NewsSourceAssessment? {
        let domain = rawDomain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !domain.isEmpty else { return nil }
        guard let rule = rules.first(where: { rule in
            rule.domains.contains { domain == $0 || domain.hasSuffix("." + $0) }
        }) else { return nil }
        return NewsSourceAssessment(
            tier: rule.tier,
            score: rule.score,
            preferred: rule.preferred)
    }

    public static func assessment(forURL url: String) -> NewsSourceAssessment? {
        guard let host = URL(string: url)?.host else { return nil }
        return assessment(forDomain: host)
    }
}

public struct NewsRefreshResult: Sendable, Equatable {
    public var topicID: UUID
    public var acceptedArticles: Int
    public var sourceFailures: [String]
    public var refreshedAt: Date

    public init(topicID: UUID, acceptedArticles: Int, sourceFailures: [String], refreshedAt: Date) {
        self.topicID = topicID
        self.acceptedArticles = acceptedArticles
        self.sourceFailures = sourceFailures
        self.refreshedAt = refreshedAt
    }
}

private struct DirectFeed: Sendable {
    var name: String
    var url: String
    var maximumItems: Int? = nil
    var prefixesTitle: Bool = false
    var publisherURLOverride: String? = nil
    var excludesPrereleases: Bool = false
}

struct RawNewsItem: Sendable, Equatable {
    var title = ""
    var link = ""
    var guid = ""
    var summary = ""
    var imageURL: String?
    var publishedAt: Date?
    var sourceName = ""
    var sourceURL = ""
    var isSearchResult = false
}

private struct RankedNewsItem: Sendable {
    var raw: RawNewsItem
    var assessment: NewsSourceAssessment
    var sourceDomain: String
    var score: Double
}

public actor NewsFeedService {
    private struct CachedFeed {
        var fetchedAt: Date
        var items: [RawNewsItem]
        var wasUnavailable: Bool
    }

    private static let responseByteLimit = 3 * 1024 * 1024
    private static let imageByteLimit = 8 * 1024 * 1024
    private static let feedAccept =
        "application/rss+xml, application/atom+xml, application/xml, text/xml;q=0.9"
    private static let imageAccept = "image/avif, image/webp, image/png, image/jpeg, image/*;q=0.8"
    private static let directCacheLifetime: TimeInterval = 15 * 60
    private static let directFeeds: [DirectFeed] = [
        DirectFeed(name: "DER SPIEGEL", url: "https://www.spiegel.de/schlagzeilen/index.rss"),
        DirectFeed(name: "Tagesschau", url: "https://www.tagesschau.de/infoservices/alle-meldungen-100~rss2.xml"),
        DirectFeed(name: "BBC News", url: "https://feeds.bbci.co.uk/news/world/rss.xml"),
        DirectFeed(name: "DW", url: "https://rss.dw.com/rdf/rss-en-all"),
        DirectFeed(name: "Nature", url: "https://www.nature.com/nature.rss"),
        DirectFeed(name: "Ars Technica", url: "https://feeds.arstechnica.com/arstechnica/index"),
        DirectFeed(name: "TechCrunch", url: "https://techcrunch.com/feed/"),
        DirectFeed(name: "The Verge", url: "https://www.theverge.com/rss/index.xml"),
        DirectFeed(name: "OpenAI", url: "https://openai.com/news/rss.xml"),
        DirectFeed(name: "Google DeepMind", url: "https://deepmind.google/blog/rss.xml"),
        DirectFeed(name: "Hugging Face", url: "https://huggingface.co/blog/feed.xml"),
        DirectFeed(name: "GitHub", url: "https://github.blog/feed/"),
        DirectFeed(
            name: "Claude Code",
            url: "https://github.com/anthropics/claude-code/releases.atom",
            maximumItems: 1,
            prefixesTitle: true,
            publisherURLOverride: "https://www.anthropic.com"),
        DirectFeed(
            name: "OpenAI Codex",
            url: "https://github.com/openai/codex/releases.atom",
            maximumItems: 1,
            prefixesTitle: true,
            publisherURLOverride: "https://openai.com",
            excludesPrereleases: true),
        DirectFeed(
            name: "Microsoft Developer Blogs",
            url: "https://devblogs.microsoft.com/feed/"),
        DirectFeed(
            name: "Simon Willison",
            url: "https://simonwillison.net/atom/everything/"),
        DirectFeed(
            name: "One Useful Thing",
            url: "https://www.oneusefulthing.org/feed")
    ]

    private let stores: Stores
    private let session: URLSession
    private var directCache: [String: CachedFeed] = [:]
    private var automaticRetryAfter: [UUID: Date] = [:]

    public init(stores: Stores, session: URLSession = ConnectorHTTPSession.make()) {
        self.stores = stores
        self.session = session
    }

    public func refresh(topic: NewsTopic, at date: Date = .now) async throws -> NewsRefreshResult {
        guard topic.isEnabled else {
            return NewsRefreshResult(
                topicID: topic.id, acceptedArticles: 0,
                sourceFailures: [], refreshedAt: date)
        }

        var failures: [String] = []
        var rawItems: [RawNewsItem] = []

        do {
            let searchURL = try Self.googleNewsURL(
                query: topic.query,
                interval: topic.refreshIntervalValue,
                locale: .current)
            let data = try await Self.fetch(url: searchURL, session: session)
            rawItems += Self.parseFeed(data: data, defaultSourceName: "", isSearchResult: true)
        } catch {
            failures.append("Google News discovery")
        }

        let direct = await directFeedItems(at: date)
        rawItems += direct.items
        failures += direct.failures

        guard !rawItems.isEmpty else {
            throw ConnectorError("News refresh failed: no configured source could be reached.")
        }

        let articles = Self.rankAndBuild(rawItems, topic: topic, fetchedAt: date)
        try stores.replaceNewsArticles(articles, for: topic.id, fetchedAt: date)
        return NewsRefreshResult(
            topicID: topic.id,
            acceptedArticles: articles.count,
            sourceFailures: Array(Set(failures)).sorted(),
            refreshedAt: date)
    }

    public func refreshDue(at date: Date = .now) async -> [NewsRefreshResult] {
        guard let due = try? stores.dueNewsTopics(at: date) else { return [] }
        var results: [NewsRefreshResult] = []
        for topic in due where automaticRetryAfter[topic.id, default: .distantPast] <= date {
            if Task.isCancelled { break }
            do {
                let result = try await refresh(topic: topic, at: date)
                automaticRetryAfter[topic.id] = nil
                results.append(result)
            } catch {
                // Silent scheduling must not hammer every source once a
                // minute during an outage. Explicit refresh remains immediate.
                automaticRetryAfter[topic.id] = date.addingTimeInterval(15 * 60)
            }
        }
        return results
    }

    /// Images cross the same DNS and manual-redirect checks as feeds. SwiftUI
    /// must not fetch attacker-controlled image URLs with its default loader,
    /// which could follow a redirect into a private or loopback address.
    public func imageData(for url: URL) async throws -> Data {
        try await Self.fetch(
            url: url,
            session: session,
            maximumBytes: Self.imageByteLimit,
            accept: Self.imageAccept)
    }

    private func directFeedItems(at date: Date) async -> (items: [RawNewsItem], failures: [String]) {
        var items: [RawNewsItem] = []
        var failures: [String] = []
        var missing: [DirectFeed] = []
        for feed in Self.directFeeds {
            if let cached = directCache[feed.url],
               date.timeIntervalSince(cached.fetchedAt) < Self.directCacheLifetime {
                items += cached.items
                if cached.wasUnavailable { failures.append(feed.name) }
            } else {
                missing.append(feed)
            }
        }

        let session = self.session
        let outcomes = await withTaskGroup(
            of: (DirectFeed, Result<[RawNewsItem], Error>).self,
            returning: [(DirectFeed, Result<[RawNewsItem], Error>)].self
        ) { group in
            for feed in missing {
                group.addTask {
                    do {
                        guard let url = URL(string: feed.url) else {
                            throw ConnectorError("Invalid built-in news source.")
                        }
                        let data = try await Self.fetch(url: url, session: session)
                        var parsed = Self.parseFeed(
                            data: data, defaultSourceName: feed.name, isSearchResult: false)
                        if let publisherURL = feed.publisherURLOverride {
                            for index in parsed.indices {
                                parsed[index].sourceURL = publisherURL
                            }
                        }
                        if feed.excludesPrereleases {
                            parsed.removeAll { item in
                                let title = item.title.lowercased()
                                return title.contains("-alpha")
                                    || title.contains("-beta")
                                    || title.contains("-rc")
                                    || title.contains("nightly")
                            }
                        }
                        if feed.prefixesTitle {
                            for index in parsed.indices {
                                parsed[index].title = "\(feed.name) \(parsed[index].title)"
                            }
                        }
                        if let maximumItems = feed.maximumItems {
                            parsed = Array(parsed.prefix(maximumItems))
                        }
                        return (feed, .success(parsed))
                    } catch {
                        return (feed, .failure(error))
                    }
                }
            }
            var values: [(DirectFeed, Result<[RawNewsItem], Error>)] = []
            for await value in group { values.append(value) }
            return values
        }

        for (feed, outcome) in outcomes {
            switch outcome {
            case .success(let fresh):
                directCache[feed.url] = CachedFeed(
                    fetchedAt: date, items: fresh, wasUnavailable: false)
                items += fresh
            case .failure:
                directCache[feed.url] = CachedFeed(
                    fetchedAt: date, items: [], wasUnavailable: true)
                failures.append(feed.name)
            }
        }
        return (items, failures)
    }

    static func fetch(
        url: URL,
        session: URLSession,
        maximumBytes: Int = responseByteLimit,
        accept: String = feedAccept
    ) async throws -> Data {
        do {
            var current = try WebConnector.validatedFetchURL(url.absoluteString)
            let noRedirects = NoRedirectsDelegate()
            for redirectCount in 0...5 {
                try await WebConnector.validatePublicResolution(host: current.host!)
                var request = URLRequest(url: current, timeoutInterval: 30)
                request.setValue(
                    "Aitvaras/0.1 PersonalNewsReader (+local macOS app)",
                    forHTTPHeaderField: "User-Agent")
                request.setValue(accept, forHTTPHeaderField: "Accept")
                let (data, response) = try await BoundedHTTP.data(
                    for: request, using: session,
                    maximumBytes: maximumBytes,
                    delegate: noRedirects)
                guard let http = response as? HTTPURLResponse else {
                    throw ConnectorError("News source returned an invalid response.")
                }
                if [301, 302, 303, 307, 308].contains(http.statusCode),
                   let location = http.value(forHTTPHeaderField: "Location") {
                    guard redirectCount < 5,
                          let redirected = URL(string: location, relativeTo: current)?.absoluteURL else {
                        throw ConnectorError("News source redirected too many times.")
                    }
                    current = try WebConnector.validatedFetchURL(redirected.absoluteString)
                    continue
                }
                guard (200..<300).contains(http.statusCode) else {
                    throw ConnectorError("News source returned an unsuccessful response.")
                }
                return data
            }
            throw ConnectorError("News source redirected too many times.")
        } catch let error as ConnectorError {
            throw error
        } catch {
            throw ConnectorDiagnostics.networkFailure(operation: "News source", error: error)
        }
    }

    static func googleNewsURL(
        query: String,
        interval: NewsRefreshInterval,
        locale: Locale
    ) throws -> URL {
        let language = locale.language.languageCode?.identifier ?? "en"
        let region = locale.region?.identifier ?? (language == "de" ? "DE" : "US")
        let lookback = interval == .weekly ? "14d" : "3d"
        let queryParts = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let exclusions = queryParts.filter(Self.isExclusionTerm)
        let positiveQuery = queryParts.filter { !Self.isExclusionTerm($0) }
            .joined(separator: " ")
        let scopedQuery = positiveQuery.range(
            of: #"(?i)\s+OR\s+"#,
            options: .regularExpression) == nil ? positiveQuery : "(\(positiveQuery))"
        let completeQuery = ([scopedQuery] + exclusions + ["when:\(lookback)"])
            .joined(separator: " ")
        var components = URLComponents(string: "https://news.google.com/rss/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: completeQuery),
            URLQueryItem(name: "hl", value: "\(language)-\(region)"),
            URLQueryItem(name: "gl", value: region),
            URLQueryItem(name: "ceid", value: "\(region):\(language)")
        ]
        guard let url = components.url else {
            throw ConnectorError("The news topic could not be converted into a search URL.")
        }
        return url
    }

    static func parseFeed(
        data: Data,
        defaultSourceName: String,
        isSearchResult: Bool
    ) -> [RawNewsItem] {
        let delegate = FeedParserDelegate(
            defaultSourceName: defaultSourceName,
            isSearchResult: isSearchResult)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { return [] }
        return delegate.items
    }

    static func rankAndBuild(
        _ rawItems: [RawNewsItem],
        topic: NewsTopic,
        fetchedAt: Date
    ) -> [NewsArticle] {
        let maximumAge: TimeInterval = topic.refreshIntervalValue == .weekly
            ? 14 * 86_400 : 3 * 86_400
        let cutoff = fetchedAt.addingTimeInterval(-maximumAge)
        let excludedWords = Set(topic.query
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter(isExclusionTerm)
            .map { String($0.dropFirst()).lowercased() })
        var ranked: [RankedNewsItem] = []

        for rawValue in rawItems {
            var raw = rawValue
            raw.title = cleanLine(raw.title, limit: NewsArticle.maximumTitleCharacters)
            raw.summary = cleanSummary(raw.summary, limit: NewsArticle.maximumSummaryCharacters)
            raw.sourceName = cleanLine(raw.sourceName, limit: NewsArticle.maximumSourceCharacters)
            raw.link = String(raw.link.prefix(NewsArticle.maximumURLCharacters))
            raw.imageURL = raw.imageURL.map { String($0.prefix(NewsArticle.maximumURLCharacters)) }
            let articleWords = Set(words(raw.title + " " + raw.summary))
            guard excludedWords.isDisjoint(with: articleWords) else { continue }
            guard !raw.title.isEmpty,
                  (try? WebConnector.validatedFetchURL(raw.link)) != nil,
                  let sourceURL = URL(string: raw.sourceURL),
                  ["http", "https"].contains(sourceURL.scheme?.lowercased() ?? ""),
                  let sourceHost = sourceURL.host?.lowercased(),
                  let assessment = NewsSourceCatalog.assessment(forDomain: sourceHost)
            else { continue }
            if let image = raw.imageURL,
               (try? WebConnector.validatedFetchURL(image)) == nil {
                raw.imageURL = nil
            }
            let published = raw.publishedAt ?? fetchedAt
            guard published >= cutoff,
                  published <= fetchedAt.addingTimeInterval(6 * 60 * 60) else { continue }
            let titleRelevance = topicMatchScore(text: raw.title, query: topic.query)
            let relevance = topicMatchScore(
                text: raw.title + " " + raw.summary + " " + raw.sourceName,
                query: topic.query)
            // Direct general-purpose feeds are filtered locally. A match in
            // the headline is enough; summary-only matches must cover most of
            // a multi-concept query so generic words such as "research" do
            // not flood an "artificial intelligence research" topic.
            guard raw.isSearchResult || titleRelevance >= 0.67 || relevance >= 0.67 else {
                continue
            }

            let age = max(0, fetchedAt.timeIntervalSince(published))
            let freshness: Double = if age <= 6 * 3600 { 0.06 }
                else if age <= 24 * 3600 { 0.04 }
                else { 0.015 }
            let completeness = (!raw.summary.isEmpty ? 0.02 : 0)
                + (raw.imageURL != nil ? 0.01 : 0)
            let score = assessment.score + freshness + completeness + min(0.04, relevance * 0.04)
            ranked.append(RankedNewsItem(
                raw: raw,
                assessment: assessment,
                sourceDomain: sourceHost,
                score: score))
        }

        ranked.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return ($0.raw.publishedAt ?? .distantPast) > ($1.raw.publishedAt ?? .distantPast)
        }
        ranked = Array(ranked.prefix(300))

        var clusters: [[RankedNewsItem]] = []
        for item in ranked {
            let words = titleSignature(item.raw.title)
            if let index = clusters.firstIndex(where: { cluster in
                guard let first = cluster.first else { return false }
                return similarity(words, titleSignature(first.raw.title)) >= 0.58
            }) {
                clusters[index].append(item)
            } else {
                clusters.append([item])
            }
        }

        let limit = switch topic.importanceValue {
        case .low: 6
        case .normal: 10
        case .high: 18
        }
        let ordered = clusters.compactMap { cluster -> NewsArticle? in
            guard let representative = cluster.max(by: { lhs, rhs in
                let left = lhs.score + (!lhs.raw.summary.isEmpty ? 0.015 : 0)
                let right = rhs.score + (!rhs.raw.summary.isEmpty ? 0.015 : 0)
                return left < right
            }) else { return nil }
            let sources = Array(Set(cluster.map(\.raw.sourceName).filter { !$0.isEmpty })).sorted()
            let stable = StableIdentifier.digest([
                topic.id.uuidString,
                representative.raw.guid.isEmpty ? representative.raw.link : representative.raw.guid
            ])
            let idText = String(stable.prefix(32))
            let uuidText = "\(idText.prefix(8))-\(idText.dropFirst(8).prefix(4))-\(idText.dropFirst(12).prefix(4))-\(idText.dropFirst(16).prefix(4))-\(idText.dropFirst(20).prefix(12))"
            guard let id = UUID(uuidString: uuidText) else { return nil }
            return NewsArticle(
                id: id,
                topicID: topic.id,
                title: representative.raw.title,
                sourceName: representative.raw.sourceName,
                sourceDomain: representative.sourceDomain,
                url: representative.raw.link,
                summary: representative.raw.summary,
                imageURL: representative.raw.imageURL,
                publishedAt: representative.raw.publishedAt ?? fetchedAt,
                fetchedAt: fetchedAt,
                qualityScore: representative.score + min(0.06, Double(cluster.count - 1) * 0.02),
                corroborationCount: sources.count,
                supportingSources: sources)
        }
        .sorted {
            if $0.qualityScore != $1.qualityScore { return $0.qualityScore > $1.qualityScore }
            return $0.publishedAt > $1.publishedAt
        }

        // A high-quality feed should not become a single-publication feed.
        // Admit at most two representatives per publisher first, then at most
        // one additional story from each. Quality beats filling every slot.
        var selected: [NewsArticle] = []
        var sourceCounts: [String: Int] = [:]
        for article in ordered where selected.count < limit {
            guard sourceCounts[article.sourceDomain, default: 0] < 2 else { continue }
            selected.append(article)
            sourceCounts[article.sourceDomain, default: 0] += 1
        }
        if selected.count < limit {
            let selectedIDs = Set(selected.map(\.id))
            for article in ordered
                where selected.count < limit && !selectedIDs.contains(article.id) {
                guard sourceCounts[article.sourceDomain, default: 0] < 3 else { continue }
                selected.append(article)
                sourceCounts[article.sourceDomain, default: 0] += 1
            }
        }
        return selected
    }

    private static let stopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "by", "for", "from", "in", "is", "it", "of", "on", "or", "the", "to", "with",
        "der", "die", "das", "den", "dem", "des", "ein", "eine", "einer", "eines", "im", "in", "mit", "und", "oder", "von", "zu"
    ]

    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !stopWords.contains($0) }
    }

    private static func topicMatchScore(text: String, query: String) -> Double {
        let textWords = topicConcepts(text)
        let positiveQuery = query.split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !isExclusionTerm($0) }
            .joined(separator: " ")
        let groups = positiveQuery
            .replacingOccurrences(
                of: #"(?i)\s+OR\s+"#,
                with: "\n",
                options: .regularExpression)
            .split(separator: "\n")
            .map { topicConcepts(String($0)) }
            .filter { !$0.isEmpty }
        guard !groups.isEmpty else { return 0 }
        return groups.map { concepts in
            Double(concepts.intersection(textWords).count) / Double(concepts.count)
        }.max() ?? 0
    }

    private static func isExclusionTerm(_ token: String) -> Bool {
        guard token.first == "-", token.count > 1 else { return false }
        return token.dropFirst().allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-"
        }
    }

    private static func topicConcepts(_ text: String) -> Set<String> {
        var result = Set(words(text).map { word -> String in
            switch word {
            case "european", "europe", "eu": "europe"
            case "technologies", "technology", "technological": "technology"
            case "policies", "policy": "policy"
            default: word
            }
        })
        if result.contains("artificial") && result.contains("intelligence") {
            result.remove("artificial")
            result.remove("intelligence")
            result.insert("ai")
        }
        // These words describe the desired format, not the subject. Keeping
        // them would make every paper match a topic such as "AI research".
        result.subtract([
            "research", "news", "headline", "headlines", "latest", "current",
            "update", "updates", "new", "feature", "features", "insight", "insights"
        ])
        return result
    }

    private static func titleSignature(_ title: String) -> Set<String> {
        Set(words(title).filter { $0.count > 2 })
    }

    private static func similarity(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        return Double(lhs.intersection(rhs).count) / Double(lhs.union(rhs).count)
    }

    private static func cleanLine(_ input: String, limit: Int) -> String {
        String(WebConnector.strippedOfHTML(input).prefix(limit))
    }

    private static func cleanSummary(_ input: String, limit: Int) -> String {
        let withoutFeedMetadata = input.replacingOccurrences(
            of: #"(?is)^\s*<p>\s*Nature,\s*Published online:.*?</p>\s*"#,
            with: "",
            options: .regularExpression)
        let plain = WebConnector.strippedOfHTML(withoutFeedMetadata)
            .replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
        return String(plain.prefix(limit))
    }
}

private final class FeedParserDelegate: NSObject, XMLParserDelegate {
    private let defaultSourceName: String
    private let isSearchResult: Bool
    private(set) var items: [RawNewsItem] = []
    private var item: RawNewsItem?
    private var element = ""
    private var text = ""

    init(defaultSourceName: String, isSearchResult: Bool) {
        self.defaultSourceName = defaultSourceName
        self.isSearchResult = isSearchResult
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        element = Self.normalized(qName ?? elementName)
        text = ""
        if element == "item" || element == "entry" {
            item = RawNewsItem(
                sourceName: defaultSourceName,
                isSearchResult: isSearchResult)
            return
        }
        guard item != nil else { return }
        if element == "link", let href = attributeDict["href"],
           attributeDict["rel"] == nil || attributeDict["rel"] == "alternate" {
            item?.link = href
        }
        if element == "source", let sourceURL = attributeDict["url"] {
            item?.sourceURL = sourceURL
        }
        if element == "thumbnail" || element == "content" || element == "enclosure",
           let url = attributeDict["url"], Self.looksLikeImage(url, attributes: attributeDict) {
            item?.imageURL = url
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let ended = Self.normalized(qName ?? elementName)
        guard var current = item else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch ended {
        case "title":
            if current.title.isEmpty { current.title = value }
        case "link": if current.link.isEmpty { current.link = value }
        case "guid", "id": current.guid = value
        case "description", "summary", "encoded", "content":
            if value.count > current.summary.count { current.summary = value }
            if current.imageURL == nil { current.imageURL = Self.imageURL(inHTML: value) }
        case "pubdate", "published", "updated", "date":
            current.publishedAt = current.publishedAt ?? Self.parseDate(value)
        case "source":
            if isSearchResult, !value.isEmpty { current.sourceName = value }
        case "item", "entry":
            if current.sourceURL.isEmpty,
               let host = URL(string: current.link)?.host {
                current.sourceURL = "https://\(host)"
            }
            if current.isSearchResult, !current.sourceName.isEmpty {
                let suffix = " - \(current.sourceName)"
                if current.title.hasSuffix(suffix) {
                    current.title.removeLast(suffix.count)
                }
                // Google News descriptions repeat only the linked headline
                // and publisher; they are not an editorial summary.
                current.summary = ""
            }
            items.append(current)
            item = nil
            text = ""
            return
        default: break
        }
        item = current
        text = ""
    }

    private static func normalized(_ name: String) -> String {
        name.lowercased().split(separator: ":").last.map(String.init) ?? name.lowercased()
    }

    private static func looksLikeImage(_ url: String, attributes: [String: String]) -> Bool {
        let medium = attributes["medium"]?.lowercased()
        let type = attributes["type"]?.lowercased()
        if medium == "image" || type?.hasPrefix("image/") == true { return true }
        let path = URL(string: url)?.pathExtension.lowercased() ?? ""
        return ["jpg", "jpeg", "png", "webp", "gif", "avif"].contains(path)
    }

    private static func imageURL(inHTML html: String) -> String? {
        let pattern = #"<img\b[^>]*\bsrc=[\"']([^\"']+)[\"']"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(
                in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        let value = WebConnector.decodeEntities(String(html[range]))
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme ?? "") else {
            return nil
        }
        return value
    }

    private static func parseDate(_ value: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) { return date }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm:ss Z",
            "dd MMM yyyy HH:mm:ss Z"
        ] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        formatter.dateFormat = "yyyy-MM-dd"
        if let date = formatter.date(from: value) { return date }
        return nil
    }
}
