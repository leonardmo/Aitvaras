import Foundation
import Darwin
import AitvarasCore

/// Read-only web access: DuckDuckGo search plus page fetching, reduced to
/// readable plain text before it reaches the model. Zero configuration —
/// no API key, nothing in the Keychain. Both tools are `.read` under the
/// autonomy policy (D13).
///
/// The model composes the URLs, so `fetch_page` enforces SSRF hygiene:
/// http/https only, local and private-network hosts refused. The homelab is
/// reachable exclusively through its typed read-only connectors (D10), never
/// through free-form fetching.
///
/// Parsing is dependency-free (Foundation + Swift Regex). DuckDuckGo's HTML
/// endpoint has no contract; when its layout changes or it serves a bot
/// challenge, `search` throws a clear error instead of returning nothing.
public actor WebConnector: Connector {
    public nonisolated let id = "web"
    public nonisolated let displayName = "Web"

    private let session: URLSession

    static let searchEndpoint = "https://html.duckduckgo.com/html/"
    static let requestTimeout: TimeInterval = 15
    /// Parsing happens only after download, so bound the raw response too.
    static let responseByteLimit = 2 * 1024 * 1024
    /// DDG's HTML endpoint serves a JS challenge to unknown clients; a plain
    /// desktop-browser identity keeps the static HTML coming.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

    public init(session: URLSession = ConnectorHTTPSession.make()) {
        self.session = session
    }

    public nonisolated let tools: [ToolDefinition] = [
        ToolDefinition(
            name: "search",
            description: "Web search via DuckDuckGo. Returns one compact JSON object per line with title, url and snippet. Follow up with fetch_page to read a result.",
            parametersJSON: """
            {"type":"object","properties":{"query":{"type":"string","description":"Search query"},"count":{"type":"integer","description":"How many results, max 5 (default 3)"}},"required":["query"]}
            """,
            risk: .read
        ),
        ToolDefinition(
            name: "fetch_page",
            description: "Fetch a public http(s) page and return its readable text (scripts, styles and markup removed). First line is 'TITLE — URL' after redirects. Local/private hosts are refused.",
            parametersJSON: """
            {"type":"object","properties":{"url":{"type":"string","description":"Absolute http(s) URL"},"maxChars":{"type":"integer","description":"Maximum characters of page text, max 8000 (default 5000)"}},"required":["url"]}
            """,
            risk: .read
        )
    ]

    public func health() async -> ConnectorHealth {
        .ready   // nothing to configure; individual calls fail with clear errors
    }

    public func execute(toolName: String, argumentsJSON: String) async throws -> String {
        let args = try ToolArgs(json: argumentsJSON)
        switch toolName {
        case "search":
            let query = try args.requiredString("query")
            let count = min(max(args.int("count") ?? 3, 1), 5)
            return try await search(query: query, count: count)
        case "fetch_page":
            let urlString = try args.requiredString("url")
            let maxChars = min(max(args.int("maxChars") ?? 5000, 200), 8000)
            return try await fetchPage(urlString: urlString, maxChars: maxChars)
        default:
            throw ConnectorError("Web connector has no tool named '\(toolName)'.")
        }
    }

    public func events() -> AsyncStream<ConnectorEvent> {
        AsyncStream { $0.finish() }   // pull-only connector
    }

    // MARK: - Tools

    private func search(query: String, count: Int) async throws -> String {
        guard var components = URLComponents(string: Self.searchEndpoint) else {
            throw ConnectorError("Invalid search endpoint URL.")
        }
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url else {
            throw ConnectorError("Could not build a search URL for '\(query)'.")
        }

        let (data, response) = try await fetchPublic(url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ConnectorError("DuckDuckGo search returned HTTP \(http.statusCode). Try again later.")
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw ConnectorError("DuckDuckGo search response is not readable text.")
        }

        let results = Self.parseSearchResults(html: html)
        guard !results.isEmpty else {
            throw ConnectorError("DuckDuckGo returned no parseable results for '\(query)' — either nothing matched, the result layout changed, or the request was blocked. Rephrase the query or fetch_page a known site directly.")
        }
        return results.prefix(count).map { result in
            JSONText.object([
                ("title", .string(result.title)),
                ("url", .string(result.url)),
                ("snippet", .string(result.snippet))
            ])
        }.joined(separator: "\n")
    }

    private func fetchPage(urlString: String, maxChars: Int) async throws -> String {
        let url = try Self.validatedFetchURL(urlString)
        let (data, response) = try await fetchPublic(url)

        let finalURL = response.url ?? url
        // Redirects must not smuggle the fetch onto a private host either.
        if let host = finalURL.host, Self.isPrivateHost(host) {
            throw ConnectorError("'\(urlString)' redirected to local/private host '\(host)' — refused.")
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ConnectorError("'\(finalURL.absoluteString)' returned HTTP \(http.statusCode).")
        }
        let mime = (response.mimeType ?? "text/html").lowercased()
        guard mime == "text/html" || mime == "text/plain" else {
            throw ConnectorError("'\(finalURL.absoluteString)' is '\(mime)' — only text/html and text/plain pages can be fetched.")
        }
        guard let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw ConnectorError("'\(finalURL.absoluteString)' content is not decodable text.")
        }

        if mime == "text/plain" {
            return Self.pageOutput(title: nil, finalURL: finalURL.absoluteString,
                                   text: raw.trimmingCharacters(in: .whitespacesAndNewlines),
                                   maxChars: maxChars)
        }
        let page = Self.readableText(fromHTML: raw)
        return Self.pageOutput(title: page.title, finalURL: finalURL.absoluteString,
                               text: page.text, maxChars: maxChars)
    }

    private static func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml;q=0.9,text/plain;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9,de;q=0.8", forHTTPHeaderField: "Accept-Language")
        return request
    }

    /// Follow redirects ourselves so every hop passes the same literal and
    /// DNS checks before URLSession can connect to it.
    private func fetchPublic(_ initialURL: URL) async throws -> (Data, URLResponse) {
        var url = try Self.validatedFetchURL(initialURL.absoluteString)
        let noRedirects = NoRedirectsDelegate()
        for redirectCount in 0...5 {
            try await Self.validatePublicResolution(host: url.host!)
            let (data, response) = try await BoundedHTTP.data(
                for: Self.request(for: url), using: session,
                maximumBytes: Self.responseByteLimit,
                delegate: noRedirects)
            guard let http = response as? HTTPURLResponse,
                  [301, 302, 303, 307, 308].contains(http.statusCode),
                  let location = http.value(forHTTPHeaderField: "Location") else {
                return (data, response)
            }
            guard redirectCount < 5 else {
                throw ConnectorError("Web page redirected too many times.")
            }
            guard let redirected = URL(string: location, relativeTo: url)?.absoluteURL else {
                throw ConnectorError("Web page returned an invalid redirect.")
            }
            url = try Self.validatedFetchURL(redirected.absoluteString)
        }
        throw ConnectorError("Web page redirected too many times.")
    }

    // MARK: - DDG result parsing (pure, tested)

    struct SearchResult: Sendable, Equatable {
        var title: String
        var url: String
        var snippet: String
    }

    /// Extracts result blocks from DDG's HTML SERP: anchors with class
    /// `result__a` carry title + redirect href; the nearest following
    /// `result__snippet` element is the description. Ad anchors resolve to
    /// duckduckgo.com itself (y.js) and are dropped.
    static func parseSearchResults(html: String) -> [SearchResult] {
        let anchor = /<a\b[^>]*\bclass="[^"]*\bresult__a\b[^"]*"[^>]*>(.*?)<\/a>/.dotMatchesNewlines()
        let snippet = /\bclass="[^"]*\bresult__snippet\b[^"]*"[^>]*>(.*?)<\/(?:a|div|span|td)>/.dotMatchesNewlines()
        let hrefAttr = /\bhref="([^"]*)"/

        let anchors = html.matches(of: anchor)
        var results: [SearchResult] = []
        for (index, match) in anchors.enumerated() {
            guard
                let href = match.0.firstMatch(of: hrefAttr).map({ decodeEntities(String($0.1)) }),
                let url = realURL(fromResultHref: href),
                URL(string: url)?.host?.hasSuffix("duckduckgo.com") != true
            else { continue }

            let segmentEnd = index + 1 < anchors.count ? anchors[index + 1].range.lowerBound : html.endIndex
            let segment = html[match.range.upperBound..<segmentEnd]
            results.append(SearchResult(
                title: strippedOfHTML(String(match.1)),
                url: url,
                snippet: segment.firstMatch(of: snippet).map { strippedOfHTML(String($0.1)) } ?? ""))
        }
        return results
    }

    /// DDG result hrefs are redirects like
    /// `//duckduckgo.com/l/?uddg=<urlencoded-real-url>&rut=…` — decode the
    /// `uddg` parameter to the real URL. Direct http(s) hrefs pass through;
    /// anything else (javascript:, relative paths) is rejected.
    static func realURL(fromResultHref href: String) -> String? {
        let absolute = href.hasPrefix("//") ? "https:" + href : href
        guard let components = URLComponents(string: absolute) else { return nil }
        if let real = components.queryItems?.first(where: { $0.name == "uddg" })?.value,
           real.hasPrefix("http") {
            return real
        }
        guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        return absolute
    }

    // MARK: - HTML → readable text (pure, tested)

    /// Reduces an HTML page to plain text: comments, `<script>` and `<style>`
    /// bodies dropped wholesale; `<br>`, `<p>`, `<li>`, `<h1>`–`<h6>` become
    /// line breaks; remaining tags stripped, entities decoded, blank-line
    /// runs collapsed. Returns the `<title>` separately for the header line.
    static func readableText(fromHTML html: String) -> (title: String?, text: String) {
        var work = html
        work = work.replacing(/<!--.*?-->/.dotMatchesNewlines(), with: "")
        work = work.replacing(/<script\b[^>]*>.*?<\/script>/.ignoresCase().dotMatchesNewlines(), with: "")
        work = work.replacing(/<style\b[^>]*>.*?<\/style>/.ignoresCase().dotMatchesNewlines(), with: "")

        // The title goes into the header line, not the body text.
        let titleElement = /<title\b[^>]*>(.*?)<\/title>/.ignoresCase().dotMatchesNewlines()
        let title = work.firstMatch(of: titleElement)
            .map { strippedOfHTML(String($0.1)) }
            .flatMap { $0.isEmpty ? nil : $0 }
        work = work.replacing(titleElement, with: "")

        // Source whitespace is insignificant in HTML; structure comes from tags.
        work = work.replacing(/[\r\n\t]+/, with: " ")
        work = work.replacing(/<\/?(?:br|p|li|h[1-6])\b[^>]*\/?>/.ignoresCase(), with: "\n")

        let text = decodeEntities(removeTags(work))
        var lines: [String] = []
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            if line.isEmpty {
                // At most one blank line in a row (never >2 consecutive newlines).
                if lines.isEmpty || lines.last == "" { continue }
                lines.append("")
            } else {
                lines.append(line)
            }
        }
        if lines.last == "" { lines.removeLast() }
        return (title, lines.joined(separator: "\n"))
    }

    /// Final tool output: "TITLE — URL" header (URL alone when the page has
    /// no title), blank line, then the page text truncated to `maxChars`.
    static func pageOutput(title: String?, finalURL: String, text: String, maxChars: Int) -> String {
        let header = title.map { "\($0) — \(finalURL)" } ?? finalURL
        guard !text.isEmpty else { return header + "\n\n(page has no readable text)" }
        return header + "\n\n" + truncated(text, limit: maxChars)
    }

    /// Tags removed, entities decoded, whitespace collapsed to single spaces —
    /// for one-line fields like titles and snippets.
    static func strippedOfHTML(_ html: String) -> String {
        decodeEntities(removeTags(html))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// Removes `<…>` spans. A `<` that never closes is kept as literal text.
    static func removeTags(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "<", let close = s[i...].firstIndex(of: ">") {
                i = s.index(after: close)
            } else {
                out.append(s[i])
                i = s.index(after: i)
            }
        }
        return out
    }

    /// Single-pass decode of the entities DDG and common pages emit:
    /// `&amp;` `&lt;` `&gt;` `&quot;` `&apos;` `&nbsp;` (as plain space) plus
    /// numeric forms (`&#39;`, `&#x27;`). Unknown entities stay literal;
    /// double-encoded input is decoded exactly once.
    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let named: [String: Character] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "
        ]
        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            guard s[i] == "&",
                  let semi = s[i...].firstIndex(of: ";"),
                  s.distance(from: i, to: semi) <= 10
            else {
                out.append(s[i])
                i = s.index(after: i)
                continue
            }
            let body = String(s[s.index(after: i)..<semi])
            if body.hasPrefix("#") {
                let numeric = body.dropFirst()
                let value = numeric.hasPrefix("x") || numeric.hasPrefix("X")
                    ? UInt32(numeric.dropFirst(), radix: 16)
                    : UInt32(numeric)
                if let value, let scalar = Unicode.Scalar(value) {
                    out.unicodeScalars.append(scalar)
                    i = s.index(after: semi)
                    continue
                }
            } else if let character = named[body.lowercased()] {
                out.append(character)
                i = s.index(after: semi)
                continue
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }

    // MARK: - URL validation (pure, tested)

    /// http/https with a public host, or a thrown ConnectorError. The model
    /// composes these URLs, so local and private-network targets are refused
    /// outright (SSRF hygiene; homelab access goes through D10 connectors).
    static func validatedFetchURL(_ string: String) throws -> URL {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased() else {
            throw ConnectorError("Not a valid absolute URL: \(string)")
        }
        guard scheme == "http" || scheme == "https" else {
            throw ConnectorError("Only http/https URLs can be fetched, not '\(scheme):'.")
        }
        guard let host = url.host, !host.isEmpty else {
            throw ConnectorError("URL has no host: \(string)")
        }
        guard url.user == nil, url.password == nil else {
            throw ConnectorError("Web URLs containing credentials are not allowed.")
        }
        guard !isPrivateHost(host) else {
            throw ConnectorError("Refusing to fetch '\(host)' — local and private-network addresses are off limits for web fetching.")
        }
        return url
    }

    static func isPrivateHost(_ host: String) -> Bool {
        var h = host.lowercased().trimmingCharacters(
            in: CharacterSet(charactersIn: "[]"))
        while h.hasSuffix(".") { h.removeLast() }
        guard !h.isEmpty else { return true }

        var ipv4 = in_addr()
        if inet_aton(h, &ipv4) == 1 {
            return isPrivateIPv4(ipv4)
        }
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, h, &ipv6) == 1 {
            return isPrivateIPv6(ipv6)
        }
        if h.contains(":") { return true } // malformed/zone-scoped IPv6

        if h == "localhost" || !h.contains(".") { return true }
        let privateSuffixes = [
            ".local", ".localhost", ".localdomain", ".internal", ".home", ".lan", ".arpa"
        ]
        return privateSuffixes.contains { h.hasSuffix($0) }
    }

    private static func isPrivateIPv4(_ address: in_addr) -> Bool {
        var copy = address
        let b = withUnsafeBytes(of: &copy) { Array($0) }
        guard b.count == 4 else { return true }
        if b[0] == 0 || b[0] == 10 || b[0] == 127 || b[0] >= 224 { return true }
        if b[0] == 100, (64...127).contains(b[1]) { return true }
        if b[0] == 169, b[1] == 254 { return true }
        if b[0] == 172, (16...31).contains(b[1]) { return true }
        if b[0] == 192, b[1] == 168 { return true }
        if b[0] == 192, b[1] == 0, b[2] == 0 { return true }
        if b[0] == 192, b[1] == 0, b[2] == 2 { return true }
        if b[0] == 192, b[1] == 88, b[2] == 99 { return true }
        if b[0] == 198, (18...19).contains(b[1]) { return true }
        if b[0] == 198, b[1] == 51, b[2] == 100 { return true }
        if b[0] == 203, b[1] == 0, b[2] == 113 { return true }
        return false
    }

    private static func isPrivateIPv6(_ address: in6_addr) -> Bool {
        var copy = address
        let b = withUnsafeBytes(of: &copy) { Array($0) }
        guard b.count == 16 else { return true }

        // IPv4-compatible/mapped forms inherit the embedded IPv4 policy.
        if b.prefix(10).allSatisfy({ $0 == 0 }),
           (b[10] == 0 && b[11] == 0 || b[10] == 0xff && b[11] == 0xff) {
            var ipv4 = in_addr()
            withUnsafeMutableBytes(of: &ipv4) { destination in
                destination.copyBytes(from: b[12..<16])
            }
            return isPrivateIPv4(ipv4)
        }

        // Currently allocated global unicast is 2000::/3. Everything else
        // includes unspecified, loopback, ULA, link/site-local and multicast.
        guard b[0] & 0xe0 == 0x20 else { return true }
        if b[0] == 0x20, b[1] == 0x01, b[2] == 0x0d, b[3] == 0xb8 {
            return true // documentation range 2001:db8::/32
        }
        return false
    }

    static func validatePublicResolution(host: String) async throws {
        let containsPrivate = try await Task.detached(priority: .utility) {
            try resolvedAddressesContainPrivateAddress(host)
        }.value
        guard !containsPrivate else {
            throw ConnectorError(
                "Refusing to fetch '\(host)' because it resolves to a local/private address.")
        }
    }

    nonisolated private static func resolvedAddressesContainPrivateAddress(
        _ host: String
    ) throws -> Bool {
        var results: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, nil, &results)
        guard status == 0, let first = results else {
            throw ConnectorError("Web host could not be resolved.")
        }
        defer { freeaddrinfo(first) }

        var foundAddress = false
        var current: UnsafeMutablePointer<addrinfo>? = first
        while let info = current?.pointee {
            defer { current = info.ai_next }
            guard let socketAddress = info.ai_addr else { continue }
            if info.ai_family == AF_INET {
                foundAddress = true
                let value = socketAddress.withMemoryRebound(
                    to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                if isPrivateIPv4(value) { return true }
            } else if info.ai_family == AF_INET6 {
                foundAddress = true
                let value = socketAddress.withMemoryRebound(
                    to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                if isPrivateIPv6(value) { return true }
            }
        }
        guard foundAddress else {
            throw ConnectorError("Web host did not resolve to an IP address.")
        }
        return false
    }
}

final class NoRedirectsDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
