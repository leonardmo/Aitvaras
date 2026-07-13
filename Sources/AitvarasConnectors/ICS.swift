import Foundation

/// Minimal iCalendar (RFC 5545) parser — just enough for Moodle's calendar
/// export (D9 phase 1): VEVENTs with SUMMARY, DTSTART, UID, DESCRIPTION and
/// CATEGORIES. Deliberately dependency-free.
enum ICS {

    struct Event: Sendable, Equatable {
        var uid: String
        var summary: String
        var description: String
        var categories: [String]
        var start: Date?
        var isAllDay: Bool
    }

    // MARK: Parsing

    static func parse(_ text: String) -> [Event] {
        var events: [Event] = []
        var current: [String: (params: [String: String], value: String)]?

        for line in unfold(text) {
            if line == "BEGIN:VEVENT" {
                current = [:]
                continue
            }
            if line == "END:VEVENT" {
                if let props = current, let event = makeEvent(from: props) {
                    events.append(event)
                }
                current = nil
                continue
            }
            guard current != nil, let (name, params, value) = parseProperty(line) else { continue }
            current?[name] = (params, value)
        }
        return events
    }

    /// RFC 5545 line unfolding: a line starting with space or tab continues
    /// the previous line (the leading fold character is dropped).
    static func unfold(_ text: String) -> [String] {
        var lines: [String] = []
        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if (line.hasPrefix(" ") || line.hasPrefix("\t")), !lines.isEmpty {
                lines[lines.count - 1] += String(line.dropFirst())
            } else if !line.isEmpty {
                lines.append(line)
            }
        }
        return lines
    }

    /// Splits "NAME;PARAM=VAL;PARAM=VAL:value" into its parts.
    static func parseProperty(_ line: String) -> (name: String, params: [String: String], value: String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let head = String(line[line.startIndex..<colon])
        let value = String(line[line.index(after: colon)...])

        var headParts = head.split(separator: ";").map(String.init)
        guard let name = headParts.first, !name.isEmpty else { return nil }
        headParts.removeFirst()

        var params: [String: String] = [:]
        for part in headParts {
            guard let eq = part.firstIndex(of: "=") else { continue }
            let key = String(part[part.startIndex..<eq]).uppercased()
            params[key] = String(part[part.index(after: eq)...])
        }
        return (name.uppercased(), params, value)
    }

    /// Unescapes RFC 5545 TEXT values: \n, \, \; \\ .
    static func unescapeText(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        var iterator = value.makeIterator()
        while let c = iterator.next() {
            guard c == "\\", let next = iterator.next() else {
                out.append(c)
                continue
            }
            switch next {
            case "n", "N": out.append("\n")
            case ",": out.append(",")
            case ";": out.append(";")
            case "\\": out.append("\\")
            default:
                out.append(c)
                out.append(next)
            }
        }
        return out
    }

    /// Parses a DTSTART/DTEND value.
    /// - `VALUE=DATE` / bare "yyyyMMdd" → all-day, local midnight.
    /// - "yyyyMMdd'T'HHmmss'Z'" → UTC.
    /// - `TZID=<zone>` → that timezone.
    /// - floating "yyyyMMdd'T'HHmmss" → local time.
    static func parseDate(_ value: String, params: [String: String]) -> (date: Date?, isAllDay: Bool) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)

        if params["VALUE"] == "DATE" || (value.count == 8 && !value.contains("T")) {
            formatter.dateFormat = "yyyyMMdd"
            formatter.timeZone = .current
            return (formatter.date(from: value), true)
        }

        if value.hasSuffix("Z") {
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            formatter.timeZone = TimeZone(identifier: "UTC")
            return (formatter.date(from: value), false)
        }

        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        if let tzid = params["TZID"], let zone = TimeZone(identifier: tzid) {
            formatter.timeZone = zone
        } else {
            formatter.timeZone = .current
        }
        return (formatter.date(from: value), false)
    }

    // MARK: - Private

    private static func makeEvent(from props: [String: (params: [String: String], value: String)]) -> Event? {
        guard let uid = props["UID"]?.value, !uid.isEmpty else { return nil }

        var start: Date?
        var isAllDay = false
        if let dtstart = props["DTSTART"] {
            (start, isAllDay) = parseDate(dtstart.value, params: dtstart.params)
        }

        let categories = props["CATEGORIES"].map {
            $0.value.split(separator: ",").map { unescapeText(String($0)).trimmingCharacters(in: .whitespaces) }
        } ?? []

        return Event(
            uid: uid,
            summary: unescapeText(props["SUMMARY"]?.value ?? ""),
            description: unescapeText(props["DESCRIPTION"]?.value ?? ""),
            categories: categories,
            start: start,
            isAllDay: isAllDay)
    }
}
