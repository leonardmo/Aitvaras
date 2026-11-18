import Foundation

/// JSON keys are compared by decoded UTF-8 bytes, never Swift's canonical
/// equivalence. This pass runs before Foundation can discard duplicate keys.
struct AgentMCPJSON {
    let fields: [(Data, Data)]?
    let canonical: Data
    fileprivate static func object(_ fields: [(Data, Data)]) throws -> Self {
        let values = try fields.sorted { $0.0.lexicographicallyPrecedes($1.0) }.map { key, value in
            try quoted(String(decoding: key, as: UTF8.self)) + Data(":".utf8) + value
        }
        return .init(fields: fields, canonical: Data("{".utf8) + joined(values) + Data("}".utf8))
    }
    fileprivate static func array(_ values: [Self]) -> Self {
        .init(fields: nil, canonical: Data("[".utf8) + joined(values.map(\.canonical)) + Data("]".utf8))
    }
    fileprivate static func scalar(_ data: Data) -> Self { .init(fields: nil, canonical: data) }
    private static func joined(_ values: [Data]) -> Data {
        var result = Data()
        for (index, value) in values.enumerated() { if index > 0 { result.append(44) }; result.append(value) }
        return result
    }
    fileprivate static func quoted(_ text: String) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(text)
    }
    static func parse(_ data: Data) throws -> Self {
        var parser = AgentMCPJSONParser(bytes: Array(data))
        let value = try parser.value(depth: 0)
        parser.space()
        guard parser.index == parser.bytes.count else { throw AgentMCPError.invalidRepository }
        return value
    }
}

private struct AgentMCPJSONParser {
    let bytes: [UInt8]
    var index = 0
    var tokens = 0
    mutating func space() { while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
    mutating func take(_ byte: UInt8) -> Bool {
        space(); guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1; return true
    }
    mutating func string() throws -> String {
        space(); let start = index
        guard index < bytes.count, bytes[index] == 34 else { throw AgentMCPError.invalidRepository }
        index += 1
        while index < bytes.count {
            let byte = bytes[index]; index += 1
            if byte == 34 { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) }
            if byte == 92 { guard index < bytes.count else { break }; index += 1 }
        }
        throw AgentMCPError.invalidRepository
    }
    mutating func value(depth: Int) throws -> AgentMCPJSON {
        space(); tokens += 1
        guard depth < 64, tokens <= 100_000, index < bytes.count else { throw AgentMCPError.invalidRepository }
        if take(123) {
            var fields: [(Data, Data)] = [], seen = Set<Data>()
            if take(125) { return try .object(fields) }
            repeat {
                let key = Data(try string().utf8)
                guard seen.insert(key).inserted, take(58) else { throw AgentMCPError.invalidRepository }
                fields.append((key, try value(depth: depth + 1).canonical))
                if take(125) { return try .object(fields) }
            } while take(44)
            throw AgentMCPError.invalidRepository
        }
        if take(91) {
            var values: [AgentMCPJSON] = []
            if take(93) { return .array(values) }
            repeat {
                values.append(try value(depth: depth + 1))
                if take(93) { return .array(values) }
            } while take(44)
            throw AgentMCPError.invalidRepository
        }
        if bytes[index] == 34 { return .scalar(try AgentMCPJSON.quoted(string())) }
        let start = index
        while index < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
        guard start < index else { throw AgentMCPError.invalidRepository }
        let scalar = try JSONSerialization.jsonObject(with: Data(bytes[start..<index]), options: [.fragmentsAllowed])
        guard !(scalar is [Any]), !(scalar is [String: Any]), !(scalar is String) else { throw AgentMCPError.invalidRepository }
        return .scalar(try JSONSerialization.data(withJSONObject: scalar, options: [.fragmentsAllowed, .sortedKeys]))
    }
}
