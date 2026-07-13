import Foundation
import AitvarasCore

/// Error thrown by connectors, with a message meant to be readable both by
/// the model (so it can recover / rephrase) and by the user in the activity
/// log (D13).
public struct ConnectorError: Error, LocalizedError, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// Decoded tool-call arguments (the raw JSON object the model produced).
/// Lenient on types: numbers arriving as strings and vice versa are accepted,
/// because small local models are not always schema-strict.
struct ToolArgs {
    private let dict: [String: Any]

    init(json: String) throws {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            self.dict = [:]
            return
        }
        guard
            let data = trimmed.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let dict = object as? [String: Any]
        else {
            throw ConnectorError("Tool arguments must be a JSON object, got: \(json.prefix(200))")
        }
        self.dict = dict
    }

    func string(_ key: String) -> String? {
        if let s = dict[key] as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let n = dict[key] as? NSNumber { return n.stringValue }
        return nil
    }

    func requiredString(_ key: String) throws -> String {
        guard let value = string(key) else {
            throw ConnectorError("Missing required argument '\(key)'.")
        }
        return value
    }

    func int(_ key: String) -> Int? {
        if let n = dict[key] as? NSNumber { return n.intValue }
        if let s = dict[key] as? String { return Int(s) }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        if let b = dict[key] as? Bool { return b }
        if let s = dict[key] as? String { return Bool(s.lowercased()) }
        return nil
    }

    /// Every argument as a string, for `{placeholder}` substitution in
    /// manifest paths / body templates (D17).
    var stringified: [String: String] {
        var result: [String: String] = [:]
        for (key, value) in dict {
            switch value {
            case let s as String: result[key] = s
            case let b as Bool: result[key] = b ? "true" : "false"
            case let n as NSNumber: result[key] = n.stringValue
            case is NSNull: continue
            default:
                if JSONSerialization.isValidJSONObject(value),
                   let data = try? JSONSerialization.data(withJSONObject: value),
                   let s = String(data: data, encoding: .utf8) {
                    result[key] = s
                }
            }
        }
        return result
    }
}

/// ISO-8601 parsing/formatting for tool arguments. Accepts full timestamps
/// with or without fractional seconds or timezone, and plain dates
/// ("2026-07-04" — interpreted in the local timezone).
enum ISO {
    static func parseDate(_ string: String) -> Date? {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines)

        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: s) { return d }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: s) { return d }

        // No timezone suffix → local time.
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = .current
        local.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        if let d = local.date(from: s) { return d }

        // Date only → local midnight.
        local.dateFormat = "yyyy-MM-dd"
        if let d = local.date(from: s) { return d }

        return nil
    }

    static func requireDate(_ string: String, argument: String) throws -> Date {
        // Models regularly write "T24:00:00" for end-of-day — normalize
        // to next-day midnight instead of failing the whole tool call.
        if string.contains("T24:00") {
            let normalized = string.replacingOccurrences(of: "T24:00", with: "T00:00")
            if let date = parseDate(normalized) {
                return date.addingTimeInterval(24 * 60 * 60)
            }
        }
        guard let date = parseDate(string) else {
            throw ConnectorError("Argument '\(argument)' is not a valid ISO-8601 date: \(string)")
        }
        return date
    }

    static func string(from date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}

/// Minimal ordered compact-JSON writer for tool output ("JSON lines").
/// JSONSerialization loses key order and is awkward for mixed optionals;
/// tool results read better with stable field order.
enum JSONText {
    /// A value that can appear in a JSON line.
    enum Value {
        case string(String)
        case int(Int)
        case double(Double)
        case bool(Bool)
    }

    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count + 8)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    /// Compact JSON object preserving pair order; nil values are skipped.
    static func object(_ pairs: [(String, Value?)]) -> String {
        let fields = pairs.compactMap { key, value -> String? in
            guard let value else { return nil }
            let rendered: String
            switch value {
            case .string(let s): rendered = "\"\(escape(s))\""
            case .int(let i): rendered = String(i)
            case .double(let d): rendered = String(d)
            case .bool(let b): rendered = b ? "true" : "false"
            }
            return "\"\(escape(key))\":\(rendered)"
        }
        return "{" + fields.joined(separator: ",") + "}"
    }
}

/// Truncate long tool output so it cannot blow up the model context.
func truncated(_ s: String, limit: Int) -> String {
    guard s.count > limit else { return s }
    return String(s.prefix(limit)) + "\n…[truncated, \(s.count) chars total]"
}
