import Foundation
import Synchronization
import Testing
import AitvarasCore
@testable import AitvarasConnectors

private final class HomeAssistantURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status: Int
        var data: Data
    }

    struct Captured: Sendable {
        var method: String
        var path: String
        var authorization: String?
        var body: Data?
    }

    private struct State: Sendable {
        var replies: [String: Reply] = [:]
        var requests: [Captured] = []
    }

    private static let state = Mutex(State())

    static func reset(_ replies: [String: Reply]) {
        state.withLock {
            $0 = State(replies: replies, requests: [])
        }
    }

    static var requests: [Captured] { state.withLock { $0.requests } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let captured = Captured(
            method: request.httpMethod ?? "GET",
            path: path,
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            body: request.httpBody ?? Self.read(request.httpBodyStream))
        let reply = Self.state.withLock { state in
            state.requests.append(captured)
            return state.replies[path] ?? Reply(status: 404, data: Data())
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: reply.status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            result.append(buffer, count: count)
        }
        return result
    }
}

@Suite(.serialized) struct HomeAssistantConnectorTests {
    private let token = "fixture-long-lived-token"

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HomeAssistantURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func reply(_ json: String, status: Int = 200) -> HomeAssistantURLProtocol.Reply {
        .init(status: status, data: Data(json.utf8))
    }

    private func connector(session: URLSession) throws -> HomeAssistantConnector {
        try HomeAssistantConnector(
            baseURL: "http://homeassistant.local:8123/",
            tokenProvider: { token }, session: session)
    }

    @Test func endpointNormalizationProtectsBearerTransport() throws {
        #expect(try HomeAssistantEndpoint.normalizedBaseURL(
            " http://homeassistant.local:8123/ ") == "http://homeassistant.local:8123")
        #expect(try HomeAssistantEndpoint.normalizedBaseURL(
            "http://127.0.0.2:8123") == "http://127.0.0.2:8123")
        #expect(try HomeAssistantEndpoint.normalizedBaseURL(
            "https://example.invalid") == "https://example.invalid")
        #expect(throws: (any Error).self) {
            try HomeAssistantEndpoint.normalizedBaseURL("http://example.invalid:8123")
        }
        #expect(throws: (any Error).self) {
            try HomeAssistantEndpoint.normalizedBaseURL("http://fcloud.example:8123")
        }
        #expect(throws: (any Error).self) {
            try HomeAssistantEndpoint.normalizedBaseURL("https://user:pass@example.invalid")
        }
        #expect(throws: (any Error).self) {
            try HomeAssistantEndpoint.normalizedBaseURL("https://example.invalid/api")
        }
    }

    @Test func healthActuallyVerifiesTheAPIAndAuthorization() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        HomeAssistantURLProtocol.reset([
            "/api": reply(#"{"message":"API running."}"#)
        ])
        let readyConnector = try connector(session: session)

        #expect(await readyConnector.health() == .ready)
        let request = try #require(HomeAssistantURLProtocol.requests.first)
        #expect(request.path == "/api")
        #expect(request.authorization == "Bearer \(token)")

        HomeAssistantURLProtocol.reset([
            "/api": reply(#"{"message":"Unauthorized"}"#, status: 401)
        ])
        let rejectedConnector = try connector(session: session)
        guard case .needsAuthentication(let message) = await rejectedConnector.health() else {
            Issue.record("Expected an authentication health failure")
            return
        }
        #expect(message.contains("rejected"))
        #expect(!message.contains(token))

        // The Connections view refreshes every 15 seconds. A rejected token
        // must be terminal for this connector instance so polling cannot trip
        // Home Assistant's persistent IP-ban threshold.
        _ = await rejectedConnector.health()
        #expect(HomeAssistantURLProtocol.requests.count == 1)

        HomeAssistantURLProtocol.reset([
            "/api": reply("403: Forbidden", status: 403)
        ])
        let forbiddenConnector = try connector(session: session)
        guard case .error(let forbiddenMessage) = await forbiddenConnector.health() else {
            Issue.record("Expected a forbidden-access health failure")
            return
        }
        #expect(forbiddenMessage.contains("IP ban"))
        #expect(!forbiddenMessage.contains(token))
        _ = await forbiddenConnector.health()
        #expect(HomeAssistantURLProtocol.requests.count == 1)
    }

    @Test func entityInventoryAndSearchAreCompactAndPrivacyConscious() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let states = #"""
        [
          {"entity_id":"light.desk","state":"on","attributes":{"friendly_name":"Desk Lamp","brightness":128,"latitude":48.1,"token_echo":"fixture-long-lived-token"},"last_changed":"2026-07-19T08:00:00+00:00"},
          {"entity_id":"sensor.kitchen_temperature","state":"22.4","attributes":{"friendly_name":"Küchentemperatur","unit_of_measurement":"°C","device_class":"temperature","longitude":11.5},"last_changed":"2026-07-19T08:01:00+00:00"},
          {"entity_id":"person.someone","state":"home","attributes":{"friendly_name":"Someone","latitude":48.1,"longitude":11.5}}
        ]
        """#
        HomeAssistantURLProtocol.reset([
            "/api/states": reply(states),
            "/api/states/sensor.kitchen_temperature": reply(#"{"entity_id":"sensor.kitchen_temperature","state":"22.4","attributes":{"friendly_name":"Küchentemperatur","unit_of_measurement":"°C","latitude":48.1},"last_changed":"2026-07-19T08:01:00+00:00"}"#)
        ])
        let connector = try connector(session: session)

        let inventory = try await connector.execute(
            toolName: "ha_states", argumentsJSON: "{}")
        #expect(inventory.contains("3 entities"))
        #expect(inventory.contains("light: 1"))
        #expect(!inventory.contains("Desk Lamp"))

        let search = try await connector.execute(
            toolName: "search_entities",
            argumentsJSON: #"{"query":"Kuchen","domain":"sensor"}"#)
        #expect(search.contains("sensor.kitchen_temperature"))
        #expect(search.contains("Küchentemperatur"))
        #expect(search.contains("unit_of_measurement"))
        #expect(!search.contains("latitude"))
        #expect(!search.contains("longitude"))
        #expect(!search.contains(token))

        let state = try await connector.execute(
            toolName: "ha_entity",
            argumentsJSON: #"{"entity_id":"sensor.kitchen_temperature"}"#)
        #expect(state.contains("22.4"))
        #expect(!state.contains("latitude"))
    }

    @Test func lightWritesAreExactIdempotentAndNumericallyTyped() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        HomeAssistantURLProtocol.reset([
            "/api/services/light/turn_on": reply("[]")
        ])
        let connector = try connector(session: session)

        let output = try await connector.execute(
            toolName: "light_on",
            argumentsJSON: #"{"entity_id":"light.desk","brightness_pct":42,"transition_seconds":3}"#)
        #expect(output == "Turned light.desk on at 42%.")
        let request = try #require(HomeAssistantURLProtocol.requests.last)
        #expect(request.method == "POST")
        #expect(request.path == "/api/services/light/turn_on")
        #expect(request.authorization == "Bearer \(token)")
        let body = try #require(request.body)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["entity_id"] as? String == "light.desk")
        #expect((object["brightness_pct"] as? NSNumber)?.intValue == 42)
        #expect((object["transition"] as? NSNumber)?.intValue == 3)

        await #expect(throws: (any Error).self) {
            try await connector.execute(
                toolName: "light_on",
                argumentsJSON: #"{"entity_id":"switch.heater"}"#)
        }
        let requestCount = HomeAssistantURLProtocol.requests.count
        await #expect(throws: (any Error).self) {
            try await connector.execute(
                toolName: "light_on",
                argumentsJSON: #"{"entity_id":"light.desk","service":"lock.unlock"}"#)
        }
        #expect(HomeAssistantURLProtocol.requests.count == requestCount)
    }

    @Test func remoteErrorsCannotEchoTheConfiguredToken() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        HomeAssistantURLProtocol.reset([
            "/api/states/light.desk": reply(
                "debug authorization=Bearer \(token)", status: 500)
        ])
        let connector = try connector(session: session)
        do {
            _ = try await connector.execute(
                toolName: "ha_entity",
                argumentsJSON: #"{"entity_id":"light.desk"}"#)
            Issue.record("Expected the server failure")
        } catch {
            #expect(!error.localizedDescription.contains(token))
            #expect(error.localizedDescription.contains("[redacted]"))
        }
    }

    @Test func toolSurfaceKeepsOnlyLightWritesAutonomous() throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let connector = try connector(session: session)
        let tools = connector.tools
        #expect(tools.map(\.name) == [
            "ha_states", "search_entities", "ha_entity", "light_off", "light_on"
        ])
        #expect(tools.filter { $0.risk == .reversibleWrite }.map(\.name)
            == ["light_off", "light_on"])
        #expect(!tools.contains { $0.risk == .confirmable })
    }
}
