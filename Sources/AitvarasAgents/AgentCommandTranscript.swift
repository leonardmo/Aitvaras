import Foundation

/// The shell result shown in the transcript, using provider data when available.
public struct AgentCommandTranscript: Equatable, Sendable {
    public enum Status: Equatable, Sendable { case running, succeeded, failed, denied, unconfirmed }

    public let command: String
    public let status: Status
    public let output: String
    public let startedAt: Date?
    public let duration: TimeInterval?
    public let exitCode: Int?

    private static let terminalEscapes = try! NSRegularExpression(
        pattern: #"\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1B]*(?:\x07|\x1B\\)|[ -/]*[@-Z\\-_])"#
    )
    private static let omission = "… [earlier output omitted]\n"

    init?(entry: AgentTranscriptEntry) {
        guard entry.kind == "tool", let payload = entry.payloadJSON.flatMap(JSONValue.parse),
              let input = payload["input"],
              AgentToolPolicy.isCommandExecution(.init(name: entry.text, input: input)),
              let invocation = input["command"]?.stringValue ??
                input["command"]?.arrayValue?.compactMap(\.stringValue).joined(separator: " "),
              !invocation.isEmpty else { return nil }

        command = Self.plainText(AgentActionPresentation.displayCommand(invocation))
        let result = payload["output"] ?? .null
        exitCode = result["exitCode"]?.int
        startedAt = payload["commandStartedAt"]?.doubleValue.map(Date.init(timeIntervalSince1970:))
        let providerDuration = result["durationMs"]?.doubleValue.map { $0 / 1_000 }
        duration = (providerDuration ?? payload["commandDuration"]?.doubleValue).flatMap { $0 >= 0 && $0.isFinite ? $0 : nil }

        if payload["isDenied"]?.boolValue == true { status = .denied }
        else if payload["completionUnconfirmed"]?.boolValue == true { status = .unconfirmed }
        else if payload["finished"]?.boolValue != true { status = .running }
        else { status = payload["isError"]?.boolValue == true ? .failed : .succeeded }
        output = Self.plainText(result["aggregatedOutput"]?.stringValue ?? result["output"]?.stringValue
            ?? (result["type"]?.stringValue == "commandExecution" ? "" : AgentTranscriptContent.display(result)))
    }

    public var tail: String {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        let nonemptyEnd = lines.last == "" ? lines.dropLast() : lines[...]
        return nonemptyEnd.suffix(7).map { String($0.prefix(1_000)) }.joined(separator: "\n")
    }

    // Strip CSI/OSC sequences for display. Keep control data out of the rendered text.
    static func plainText(_ text: String) -> String {
        let withoutEscapes = terminalEscapes.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                                      withTemplate: "")
        let lines = withoutEscapes.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return String(lines.unicodeScalars.filter { $0 == "\n" || $0 == "\t" || !CharacterSet.controlCharacters.contains($0) })
    }

    static func boundedOutputTail(_ text: String) -> String {
        let limit = AgentTranscriptContent.maximumBytes
        guard text.utf8.count > limit else { return text }
        let budget = limit - omission.utf8.count
        var count = 0
        let tail = text.reversed().prefix { character in
            count += character.utf8.count
            return count <= budget
        }
        return omission + String(tail.reversed())
    }

    static func completedOutput(_ result: JSONValue, streamed: JSONValue?) -> JSONValue {
        if let text = result.stringValue {
            return text.isEmpty ? (streamed ?? result) : .string(boundedOutputTail(text))
        }
        guard result["type"]?.stringValue == "commandExecution" else { return AgentTranscriptContent.bounded(result) }
        var value: [String: JSONValue] = ["type": .string("commandExecution")]
        for key in ["exitCode", "durationMs", "status"] { value[key] = result[key] }
        let aggregate = result["aggregatedOutput"]?.stringValue ?? ""
        value["aggregatedOutput"] = .string(boundedOutputTail(aggregate.isEmpty ? streamed?.stringValue ?? "" : aggregate))
        return .object(value)
    }
}

extension AgentTranscriptEntry {
    public var commandTranscript: AgentCommandTranscript? { .init(entry: self) }
    public var toolItemID: String? {
        guard kind == "tool" else { return nil }
        return payloadJSON.flatMap(JSONValue.parse)?["itemID"]?.stringValue
    }
}
