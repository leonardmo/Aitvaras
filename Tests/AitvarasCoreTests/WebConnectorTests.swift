import Foundation
import Testing
@testable import AitvarasConnectors

@Suite struct WebConnectorTests {
    // MARK: - Tag stripping & entity decoding

    @Test func tagStrippingAndEntityDecoding() {
        #expect(WebConnector.removeTags("a<b>c</b>d") == "acd")
        #expect(WebConnector.removeTags("no tags at all") == "no tags at all")
        // A '<' that never closes stays literal text instead of eating the rest.
        #expect(WebConnector.removeTags("3 < 5 stays") == "3 < 5 stays")

        #expect(WebConnector.decodeEntities("&amp; &lt;x&gt; &quot;y&quot; &#x27;z&#x27; a&nbsp;b &#8364;")
            == "& <x> \"y\" 'z' a b €")
        // Exactly one decoding pass: double-encoded input surfaces the entity.
        #expect(WebConnector.decodeEntities("&amp;lt;") == "&lt;")
        // Unknown entities and bare ampersands stay literal.
        #expect(WebConnector.decodeEntities("100% &unknown; A&B") == "100% &unknown; A&B")

        #expect(WebConnector.strippedOfHTML("  <b>Hello</b>\n   &amp;   <i>world</i> ") == "Hello & world")
    }

    // MARK: - DDG redirect URL extraction

    @Test func ddgRedirectHrefDecodesUddgParameter() {
        let href = "//duckduckgo.com/l/?uddg=https%3A%2F%2Fwww.example.org%2Fen%2F%3Fq%3Dhello%20world&rut=deadbeef"
        #expect(WebConnector.realURL(fromResultHref: href) == "https://www.example.org/en/?q=hello world")
        // Direct http(s) hrefs pass through untouched.
        #expect(WebConnector.realURL(fromResultHref: "https://example.com/page") == "https://example.com/page")
        // Non-web schemes and relative paths are rejected.
        #expect(WebConnector.realURL(fromResultHref: "javascript:alert(1)") == nil)
        #expect(WebConnector.realURL(fromResultHref: "/html/?q=next") == nil)
    }

    // MARK: - DDG result-block parsing

    @Test func ddgResultBlocksParseToTitleURLSnippet() {
        // Canned SERP fixture: one ad (resolves to duckduckgo.com → dropped),
        // two organic results with anchor- and div-style snippets.
        let html = """
        <div class="serp__results">
        <div class="result results_links result--ad">
          <a rel="nofollow" class="result__a" href="https://duckduckgo.com/y.js?ad_domain=ads.example&amp;u3=x">Sponsored result</a>
          <a class="result__snippet" href="https://duckduckgo.com/y.js?x">Buy things now.</a>
        </div>
        <div class="result results_links results_links_deep web-result">
          <h2 class="result__title">
            <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fwww.swift.org%2F&amp;rut=abc">Swift.org &#x27;Welcome&#x27; &amp; more</a>
          </h2>
          <a class="result__snippet" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fwww.swift.org%2F&amp;rut=abc">Swift is a <b>general-purpose</b> programming language.</a>
        </div>
        <div class="result results_links results_links_deep web-result">
          <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fdeveloper.apple.com%2Fswift%2F&amp;rut=def">Swift - Apple Developer</a>
          <div class="result__snippet">Modern, safe <b>Swift</b> from Apple.</div>
        </div>
        </div>
        """
        let results = WebConnector.parseSearchResults(html: html)
        #expect(results.count == 2)
        #expect(results[0].title == "Swift.org 'Welcome' & more")
        #expect(results[0].url == "https://www.swift.org/")
        #expect(results[0].snippet == "Swift is a general-purpose programming language.")
        #expect(results[1].title == "Swift - Apple Developer")
        #expect(results[1].url == "https://developer.apple.com/swift/")
        #expect(results[1].snippet == "Modern, safe Swift from Apple.")
    }

    @Test func ddgParsingYieldsNothingOnUnrecognizedMarkup() {
        // Block page / layout change → empty, which execute() turns into a
        // thrown ConnectorError instead of a silent empty result.
        #expect(WebConnector.parseSearchResults(html: "<html><body>Checking your browser…</body></html>").isEmpty)
    }

    // MARK: - Readable-text reduction

    @Test func readableTextDropsScriptsStylesAndKeepsStructure() {
        let html = """
        <html><head>
        <title>Aitvaras &amp;  the Web</title>
        <style>body { color: red; }</style>
        <script>console.log("<p>fake paragraph</p>");</script>
        </head><body>
        <!-- navigation chrome -->
        <h1>Main Heading</h1>
        <p>First paragraph with a <a href="/link">link</a> inside.</p>
        <ul><li>Item one</li><li>Item two</li></ul>
        <p>Closing&nbsp;words &amp; more.</p>
        <script src="app.js"></script>
        </body></html>
        """
        let page = WebConnector.readableText(fromHTML: html)
        #expect(page.title == "Aitvaras & the Web")
        #expect(!page.text.contains("console.log"))
        #expect(!page.text.contains("fake paragraph"))
        #expect(!page.text.contains("color: red"))
        #expect(!page.text.contains("navigation chrome"))
        #expect(!page.text.contains("<"))

        let lines = page.text.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(lines == [
            "Main Heading",
            "First paragraph with a link inside.",
            "Item one",
            "Item two",
            "Closing words & more."
        ])
        // Blank-line runs are collapsed: never more than two consecutive newlines.
        #expect(!page.text.contains("\n\n\n"))
    }

    @Test func pageOutputBuildsHeaderLineAndTruncates() {
        let long = String(repeating: "x", count: 500)
        let out = WebConnector.pageOutput(
            title: "Page", finalURL: "https://example.com/a", text: long, maxChars: 100)
        #expect(out.hasPrefix("Page — https://example.com/a\n\n" + String(repeating: "x", count: 100)))
        #expect(out.contains("…[truncated"))
        #expect(!out.hasSuffix(String(repeating: "x", count: 101)))

        // No title → the URL alone is the header; short text is untouched.
        let untitled = WebConnector.pageOutput(
            title: nil, finalURL: "https://example.com/b", text: "short", maxChars: 100)
        #expect(untitled == "https://example.com/b\n\nshort")
    }

    // MARK: - Fetch URL validation (SSRF hygiene)

    @Test func fetchURLValidationRejectsNonHTTPAndPrivateHosts() throws {
        #expect(throws: ConnectorError.self) { _ = try WebConnector.validatedFetchURL("file:///etc/passwd") }
        #expect(throws: ConnectorError.self) { _ = try WebConnector.validatedFetchURL("ftp://example.com/x") }
        #expect(throws: ConnectorError.self) { _ = try WebConnector.validatedFetchURL("not a url") }
        #expect(throws: ConnectorError.self) { _ = try WebConnector.validatedFetchURL("http://localhost:8080/admin") }
        #expect(throws: ConnectorError.self) { _ = try WebConnector.validatedFetchURL("http://127.0.0.1/") }
        #expect(throws: ConnectorError.self) { _ = try WebConnector.validatedFetchURL("http://10.0.0.5/") }
        #expect(throws: ConnectorError.self) { _ = try WebConnector.validatedFetchURL("https://192.168.1.10/router") }
        #expect(throws: ConnectorError.self) { _ = try WebConnector.validatedFetchURL("http://truenas.local/api") }

        #expect(try WebConnector.validatedFetchURL("https://www.example.org/").host == "www.example.org")
        #expect(try WebConnector.validatedFetchURL("http://example.com/a?b=c").absoluteString == "http://example.com/a?b=c")
    }

    @Test func privateHostDetectionCoversRangesNotJustLiterals() {
        #expect(WebConnector.isPrivateHost("172.16.0.1"))
        #expect(WebConnector.isPrivateHost("172.31.255.255"))
        #expect(!WebConnector.isPrivateHost("172.32.0.1"))
        #expect(WebConnector.isPrivateHost("169.254.1.1"))
        #expect(WebConnector.isPrivateHost("::1"))
        #expect(!WebConnector.isPrivateHost("wikipedia.org"))
        // ".local"-suffix check must not swallow normal domains.
        #expect(!WebConnector.isPrivateHost("localish.example.com"))
    }

    // MARK: - Live network (opt-in: AITVARAS_LIVE_TESTS=1)

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AITVARAS_LIVE_TESTS"] != nil))
    func liveDDGSearchReturnsJSONLines() async throws {
        let connector = WebConnector()
        let output = try await connector.execute(
            toolName: "search",
            argumentsJSON: #"{"query":"Technische Universität München","count":3}"#)
        let lines = output.split(separator: "\n")
        #expect(!lines.isEmpty && lines.count <= 3)
        #expect(lines.allSatisfy { $0.contains("\"url\":\"http") && $0.contains("\"title\":\"") })
    }
}
