import Foundation

/// Keep source OCR when exporting a refined audio transcript without duplicating
/// the original speech. Timestamps and OCR contents remain exactly as recorded.
public enum CaptureScreenText {
    public static func extract(from transcript: String) -> String {
        var result: [String] = []
        var inScreenNote = false
        for line in transcript.components(separatedBy: "\n") {
            let beginsEntry = line.range(of: #"^\[\d{2,}:\d{2}:\d{2}\] \["#, options: .regularExpression) != nil
            if beginsEntry {
                inScreenNote = line.range(of: #"^\[\d{2,}:\d{2}:\d{2}\] \[Bildschirm\]$"#, options: .regularExpression) != nil
            }
            if inScreenNote { result.append(line) }
        }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
