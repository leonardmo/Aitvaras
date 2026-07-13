import Foundation
import Testing
import AitvarasCore
@testable import AitvarasConnectors

// MARK: - Manifest (D17)

@Test func manifestRoundTripsThroughJSON() throws {
    let manifest = ConnectorManifest(
        id: "proxmox",
        displayName: "Proxmox",
        baseURL: "https://pve.local:8006",
        auth: .init(type: .header, keychainKey: "proxmox.apiToken",
                    headerName: "Authorization", valuePrefix: "PVEAPIToken="),
        tools: [
            .init(name: "cluster_status", description: "Cluster resources", method: "GET",
                  path: "/api2/json/cluster/resources",
                  parametersJSON: #"{"type":"object","properties":{},"required":[]}"#,
                  risk: .read)
        ],
        triggers: [
            .init(name: "vm_status", method: "GET", path: "/api2/json/cluster/resources",
                  intervalSeconds: 300, watchPath: "data.0.status",
                  titleTemplate: "Proxmox {name}: {previous} → {value}")
        ])

    let data = try JSONEncoder().encode(manifest)
    let decoded = try JSONDecoder().decode(ConnectorManifest.self, from: data)
    #expect(decoded == manifest)
}

@Test func manifestDecodesFromHandWrittenJSONWithoutTriggers() throws {
    // Triggers are optional in user-written manifests.
    let json = """
    {"id":"myapi","displayName":"My API","baseURL":"https://example.com",
     "auth":{"type":"bearer","keychainKey":"myapi.token"},
     "tools":[{"name":"ping","description":"Ping","method":"GET","path":"/ping",
               "parametersJSON":"{}","risk":"read"}]}
    """
    let manifest = try JSONDecoder().decode(ConnectorManifest.self, from: Data(json.utf8))
    #expect(manifest.triggers.isEmpty)
    #expect(manifest.auth.type == .bearer)
    #expect(manifest.tools.first?.risk == .read)
}

// MARK: - Placeholder substitution

@Test func pathPlaceholdersAreSubstitutedAndLeftoversBecomeQueryParams() throws {
    let request = try ManifestEngine.buildRequest(
        baseURL: "https://ha.local:8123",
        auth: .init(type: .none),
        method: "GET",
        path: "/api/states/{entity_id}",
        args: ["entity_id": "light.kitchen", "verbose": "true"],
        bodyTemplate: nil,
        secret: nil)

    let url = try #require(request.url)
    #expect(url.path == "/api/states/light.kitchen")
    #expect(url.query == "verbose=true")
    #expect(request.httpMethod == "GET")
}

@Test func leftoverArgsBecomeJSONBodyForPOST() throws {
    let request = try ManifestEngine.buildRequest(
        baseURL: "https://example.com",
        auth: .init(type: .none),
        method: "POST",
        path: "/api/items",
        args: ["title": "Hello", "count": "3"],
        bodyTemplate: nil,
        secret: nil)

    let body = try #require(request.httpBody)
    let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(object["title"] as? String == "Hello")
    #expect(object["count"] as? String == "3")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
}

@Test func bodyTemplatePlaceholdersAreSubstitutedAndJSONEscaped() throws {
    let request = try ManifestEngine.buildRequest(
        baseURL: "https://example.com",
        auth: .init(type: .none),
        method: "POST",
        path: "/api/notify",
        args: ["message": "line1\nline2 \"quoted\""],
        bodyTemplate: #"{"text":"{message}","priority":1}"#,
        secret: nil)

    let body = try #require(request.httpBody)
    // The template must remain valid JSON after substitution.
    let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(object["text"] as? String == "line1\nline2 \"quoted\"")
    #expect(object["priority"] as? Int == 1)
}

@Test func substituteReportsUsedKeys() {
    let (text, used) = ManifestEngine.substitute(
        "/nodes/{node}/vms/{vmid}", args: ["node": "pve1", "vmid": "101", "extra": "x"])
    #expect(text == "/nodes/pve1/vms/101")
    #expect(used == ["node", "vmid"])
}

// MARK: - Auth schemes

@Test func bearerAuthSetsAuthorizationHeader() throws {
    let request = try ManifestEngine.buildRequest(
        baseURL: "https://truenas.local", auth: .init(type: .bearer, keychainKey: "k"),
        method: "GET", path: "/api/v2.0/system/info", args: [:], bodyTemplate: nil,
        secret: "TOKEN123")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer TOKEN123")
}

@Test func headerAuthWithProxmoxPrefixBuildsPVEAPITokenHeader() throws {
    let request = try ManifestEngine.buildRequest(
        baseURL: "https://pve.local:8006",
        auth: .init(type: .header, keychainKey: "k",
                    headerName: "Authorization", valuePrefix: "PVEAPIToken="),
        method: "GET", path: "/api2/json/nodes", args: [:], bodyTemplate: nil,
        secret: "aitvaras@pve!readonly=uuid-1234")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "PVEAPIToken=aitvaras@pve!readonly=uuid-1234")
}

@Test func queryAuthAppendsSecretAsQueryParameter() throws {
    let request = try ManifestEngine.buildRequest(
        baseURL: "https://example.com",
        auth: .init(type: .query, keychainKey: "k", queryParam: "api_key"),
        method: "GET", path: "/v1/data", args: ["limit": "5"], bodyTemplate: nil,
        secret: "SECRET")
    let query = try #require(request.url?.query)
    #expect(query.contains("api_key=SECRET"))
    #expect(query.contains("limit=5"))
}

@Test func basicAuthEncodesUserPassAsBase64() throws {
    let request = try ManifestEngine.buildRequest(
        baseURL: "https://example.com", auth: .init(type: .basic, keychainKey: "k"),
        method: "GET", path: "/", args: [:], bodyTemplate: nil,
        secret: "user:pass")
    let expected = "Basic " + Data("user:pass".utf8).base64EncodedString()
    #expect(request.value(forHTTPHeaderField: "Authorization") == expected)
}

@Test func noneAuthSetsNothing() throws {
    let request = try ManifestEngine.buildRequest(
        baseURL: "https://example.com", auth: .init(type: .none),
        method: "GET", path: "/", args: [:], bodyTemplate: nil, secret: nil)
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
}

@Test func missingSecretThrowsActionableError() {
    #expect(throws: ConnectorError.self) {
        _ = try ManifestEngine.buildRequest(
            baseURL: "https://example.com",
            auth: .init(type: .bearer, keychainKey: "myapi.token"),
            method: "GET", path: "/", args: [:], bodyTemplate: nil, secret: nil)
    }
}

// MARK: - watchPath navigation

@Test func watchPathNavigatesDictsAndArrayIndices() throws {
    let json = try JSONSerialization.jsonObject(with: Data("""
    {"result":[{"status":"running","cpu":0.42,"ok":true},{"status":"stopped"}],"count":2}
    """.utf8))

    #expect(ManifestEngine.value(at: "result.0.status", in: json) == "running")
    #expect(ManifestEngine.value(at: "result.1.status", in: json) == "stopped")
    #expect(ManifestEngine.value(at: "count", in: json) == "2")
    #expect(ManifestEngine.value(at: "result.0.ok", in: json) == "true")
    #expect(ManifestEngine.value(at: "result.5.status", in: json) == nil)
    #expect(ManifestEngine.value(at: "missing.path", in: json) == nil)
}

// MARK: - ICS parsing (D9)

@Test func icsParsesFoldedLinesAllDayAndTimezonedEvents() {
    let ics = """
    BEGIN:VCALENDAR\r
    VERSION:2.0\r
    BEGIN:VEVENT\r
    UID:assignment-1@moodle.example.edu\r
    SUMMARY:Abgabe Übungsblatt 7 mit einem sehr langen Titel der über\r
      mehrere Zeilen gefaltet wird\r
    DESCRIPTION:Zeile eins\\nZeile zwei\\, mit Komma\r
    CATEGORIES:Analysis für Informatik\r
    DTSTART:20260710T235900Z\r
    END:VEVENT\r
    BEGIN:VEVENT\r
    UID:holiday-1@moodle.example.edu\r
    SUMMARY:Feiertag\r
    DTSTART;VALUE=DATE:20260715\r
    END:VEVENT\r
    BEGIN:VEVENT\r
    UID:lecture-1@moodle.example.edu\r
    SUMMARY:Vorlesung\r
    DTSTART;TZID=Europe/Berlin:20260716T101500\r
    END:VEVENT\r
    END:VCALENDAR\r
    """

    let events = ICS.parse(ics)
    #expect(events.count == 3)

    // Folded SUMMARY is reassembled; escaped TEXT is unescaped.
    let assignment = events[0]
    #expect(assignment.uid == "assignment-1@moodle.example.edu")
    #expect(assignment.summary == "Abgabe Übungsblatt 7 mit einem sehr langen Titel der über mehrere Zeilen gefaltet wird")
    #expect(assignment.description == "Zeile eins\nZeile zwei, mit Komma")
    #expect(assignment.categories == ["Analysis für Informatik"])
    #expect(assignment.isAllDay == false)

    // UTC datetime.
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    let utcParts = utc.dateComponents([.year, .month, .day, .hour, .minute], from: assignment.start!)
    #expect(utcParts.year == 2026 && utcParts.month == 7 && utcParts.day == 10)
    #expect(utcParts.hour == 23 && utcParts.minute == 59)

    // All-day event.
    let holiday = events[1]
    #expect(holiday.isAllDay)
    let localParts = Calendar.current.dateComponents([.year, .month, .day], from: holiday.start!)
    #expect(localParts.year == 2026 && localParts.month == 7 && localParts.day == 15)

    // TZID datetime.
    let lecture = events[2]
    var berlin = Calendar(identifier: .gregorian)
    berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
    let berlinParts = berlin.dateComponents([.hour, .minute], from: lecture.start!)
    #expect(berlinParts.hour == 10 && berlinParts.minute == 15)
}

@Test func icsUnfoldJoinsContinuationLines() {
    // RFC 5545: the CRLF and the single fold character are removed —
    // "ab" split as "a\r\n b" reassembles to "ab", not "a b".
    #expect(ICS.unfold("SUMMARY:part o\r\n ne\r\nUID:x") == ["SUMMARY:part one", "UID:x"])
    // A content space survives when the fold happens after it (two spaces:
    // fold marker + content).
    #expect(ICS.unfold("SUMMARY:part one\r\n  and part two") == ["SUMMARY:part one and part two"])
}

// MARK: - AppleScript escaping (D5)

@Test func appleScriptEscapingNeutralizesQuotesAndBackslashes() {
    #expect(appleScriptEscaped(#"plain text"#) == "plain text")
    #expect(appleScriptEscaped(#"say "hello""#) == #"say \"hello\""#)
    #expect(appleScriptEscaped(#"back\slash"#) == #"back\\slash"#)
    // Injection attempt: closing the literal and appending script code
    // must come back fully quoted.
    let hostile = #"" & (do shell script "rm -rf ~") & ""#
    let escaped = appleScriptEscaped(hostile)
    #expect(escaped == #"\" & (do shell script \"rm -rf ~\") & \""#)
}

@Test func mailMessageParsingSplitsRecordsAndFields() {
    let fs = "\u{1F}", rs = "\u{1E}"
    let raw = "id-1\(fs)Alice <a@example.com>\(fs)Hello\(fs)2026-07-04T10:00:00+02:00\(fs)Body text\(rs)"
        + "id-2\(fs)Bob <b@example.com>\(fs)Re: Hello\(fs)2026-07-04T11:00:00+02:00\(fs)Reply body\(rs)"
    let messages = MailConnector.parseMessages(raw)
    #expect(messages.count == 2)
    #expect(messages[0].messageID == "id-1")
    #expect(messages[0].sender == "Alice <a@example.com>")
    #expect(messages[0].subject == "Hello")
    #expect(messages[0].date != nil)
    #expect(messages[1].content == "Reply body")
}

// MARK: - Calendar tag guard (D6)

@Test func aitvarasTagGuardOnlyAcceptsAitvarasScheme() {
    #expect(AitvarasEventTag.isAitvarasManaged(AitvarasEventTag.makeURL()))
    #expect(AitvarasEventTag.isAitvarasManaged(URL(string: "aitvaras://event/abc")))
    #expect(!AitvarasEventTag.isAitvarasManaged(URL(string: "https://zoom.us/j/123")))
    #expect(!AitvarasEventTag.isAitvarasManaged(URL(string: "webcal://example.com/feed")))
    #expect(!AitvarasEventTag.isAitvarasManaged(nil))
    // A hostile lookalike where "aitvaras" is the host, not the scheme.
    #expect(!AitvarasEventTag.isAitvarasManaged(URL(string: "https://aitvaras/event/abc")))
}

// MARK: - Claude CLI result extraction (D14)

@Test func claudeJSONResultIsExtractedWithRawFallback() {
    let json = #"{"type":"result","is_error":false,"result":"Refactoring done, 3 files changed."}"#
    #expect(DelegateConnector.extractClaudeResult(json) == "Refactoring done, 3 files changed.")
    #expect(DelegateConnector.extractClaudeResult("not json at all") == "not json at all")
}
