import SwiftUI
import AitvarasAgents

struct ComposerContextMeter: View {
    @Environment(\.colorScheme) private var colorScheme
    let usage: AgentUsage?
    let compact: Bool

    private var fraction: Double? { ChatSettings.contextFraction(usage) }
    private var percentage: String { fraction.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "—" }
    private var detail: String {
        guard let fraction, let used = usage?.contextTokens, let limit = usage?.contextLimit else {
            return "Context window unavailable"
        }
        return "\(used.formatted()) of \(limit.formatted()) tokens used (\(fraction.formatted(.percent.precision(.fractionLength(0)))))"
    }

    var body: some View {
        let ramp = ColorRamp.context(fraction ?? 0)
        Group {
            if compact {
                ComposerMeterTrack(fraction: fraction, ramp: ramp)
                    .frame(width: 41, height: 5)
                    .frame(height: 26)
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "text.alignleft").accessibilityHidden(true)
                    Text("Context")
                    Text(percentage).fontWeight(.semibold).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.85)
                        .frame(width: 30, alignment: .trailing)
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle((colorScheme == .dark ? Color(white: 0.94) : Color(white: 0.13))
                    .opacity(fraction == nil ? 0.72 : 1))
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background { ComposerMeterTrack(fraction: fraction, ramp: ramp, behindText: true) }
                .overlay { Capsule().strokeBorder(.primary.opacity(0.18), lineWidth: 1) }
            }
        }
        .contentShape(Rectangle())
        .help(detail)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(fraction == nil ? detail : "Context window. " + detail)
        .accessibilityIdentifier(compact ? "chat.gauge.context.compact" : "chat.gauge.context")
    }
}

/// The gradient grows inside a fixed-size track and respects the app's motion preference.
struct ComposerMeterTrack: View {
    @AppReduceMotion private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    let fraction: Double?
    let ramp: ColorRamp
    var behindText = false

    var body: some View {
        GeometryReader { proxy in
            let dark = colorScheme == .dark
            Capsule().fill(Color.primary.opacity(behindText ? 0.055 : 0.15))
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(contrast == .increased
                              ? AnyShapeStyle(Color.accentColor.opacity(behindText ? 0.32 : 1))
                              : AnyShapeStyle(ramp.wash(opacity: behindText ? (dark ? 0.47 : 0.29) : 1,
                                                        from: .leading, to: .trailing)))
                        .frame(width: proxy.size.width * (fraction ?? 0))
                }
                .clipShape(Capsule())
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: fraction)
        }
        .accessibilityHidden(true)
    }
}
