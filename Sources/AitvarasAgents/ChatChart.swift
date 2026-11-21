import AppKit
import Charts
import SwiftUI

/// A bounded, declarative chart. Invalid data stays visible as fenced source.
struct ChatChart: Decodable {
    struct Datum: Decodable {
        let label: String
        let value: Double
    }

    let title: String
    let values: [Datum]

    init?(source: String) {
        guard source.utf8.count <= 8192, let chart = try? JSONDecoder().decode(Self.self, from: Data(source.utf8)),
              !chart.title.isEmpty, chart.title.count <= 80, (1...16).contains(chart.values.count),
              Set(chart.values.map(\.label)).count == chart.values.count,
              chart.values.allSatisfy({ !$0.label.isEmpty && $0.label.count <= 28 && abs($0.value) <= 1e12 })
        else { return nil }
        self = chart
    }

    @MainActor func image(appearance: NSAppearance.Name?) -> NSImage? {
        let lower = min(0, values.map(\.value).min() ?? 0)
        let upper = max(0, values.map(\.value).max() ?? 0)
        let domain = lower...(lower == upper ? 1 : upper)
        let renderer = ImageRenderer(content: VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline).lineLimit(1)
            ForEach(values, id: \.label) { datum in
                HStack(spacing: 10) {
                    Text(datum.label).lineLimit(1)
                        .frame(width: 108, alignment: .leading)
                    Chart {
                        BarMark(x: .value("Value", datum.value), y: .value("Category", datum.label),
                                height: .fixed(10))
                            .foregroundStyle(Color.accentColor)
                        if lower < 0, upper > 0 {
                            RuleMark(x: .value("Zero", 0)).foregroundStyle(Color.secondary)
                        }
                    }
                    .chartXScale(domain: domain)
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .frame(height: 18)
                    Text(datum.value.formatted(.number.precision(.significantDigits(1...6))))
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
                        .frame(width: 82, alignment: .trailing)
                }
                .font(.system(size: 12))
            }
        }
        .padding(12)
        .frame(width: 460)
        .background(Color(nsColor: .controlBackgroundColor))
        .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light))
        renderer.scale = 2
        return renderer.nsImage
    }
}

/// A figure fits its line without changing the text storage or selection.
final class ChatFigureCell: NSTextAttachmentCell {
    let sourceText: String
    let caption: String
    private let imageSize: NSSize

    init(image: NSImage, sourceText: String, caption: String) {
        self.sourceText = sourceText
        self.caption = caption
        imageSize = image.size
        super.init(imageCell: image)
    }

    required init(coder: NSCoder) { fatalError("Use init(image:sourceText:caption:)") }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect,
                            glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(1, max(1, lineFrag.width) / imageSize.width, 460 / imageSize.height)
        return NSRect(x: 0, y: 0, width: floor(imageSize.width * scale), height: floor(imageSize.height * scale))
    }
}
