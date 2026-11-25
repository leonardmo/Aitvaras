import SwiftUI
import AitvarasAgents

struct ComposerContextMeter: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var showsDetails = false
    let usage: AgentUsage?
    let compact: Bool

    private var fraction: Double? { ChatSettings.contextFraction(usage) }
    private var detail: String {
        guard let fraction, let used = usage?.contextTokens, let limit = usage?.contextLimit else {
            return "Context window unavailable"
        }
        return "\(used.formatted()) of \(limit.formatted()) tokens used (\(fraction.formatted(.percent.precision(.fractionLength(0)))))"
    }

    var body: some View {
        let ramp = ColorRamp.context(fraction ?? 0)
        Button { showsDetails.toggle() } label: {
            if compact {
                ComposerMeterTrack(fraction: fraction, ramp: ramp, rounded: false)
                    .frame(height: ComposerMeterTrack.compactRowHeight)
            } else {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle((colorScheme == .dark ? Color(white: 0.94) : Color(white: 0.13))
                        .opacity(fraction == nil ? 0.72 : 1))
                    .frame(width: 44, height: 26)
                    .background { ComposerMeterTrack(fraction: fraction, ramp: ramp, behindText: true) }
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help(detail)
        .accessibilityLabel("Context window")
        .accessibilityValue(detail)
        .accessibilityIdentifier(compact ? "chat.gauge.context.compact" : "chat.gauge.context")
        .popover(isPresented: $showsDetails, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Context window").font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            .padding(16)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("chat.context.popover")
        }
    }
}

/// The gradient grows inside a fixed-size track and respects the app's motion preference.
struct ComposerMeterTrack: View {
    static let compactRowHeight: CGFloat = 12.5

    @AppReduceMotion private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    let fraction: Double?
    let ramp: ColorRamp
    var behindText = false
    var rounded = true

    var body: some View {
        GeometryReader { proxy in
            let dark = colorScheme == .dark
            Rectangle().fill(Color.primary.opacity(behindText ? 0.055 : 0.15))
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(contrast == .increased
                              ? AnyShapeStyle(Color.accentColor.opacity(behindText ? 0.32 : 1))
                              : AnyShapeStyle(ramp.wash(opacity: behindText ? (dark ? 0.47 : 0.29) : 1,
                                                        from: .leading, to: .trailing)))
                        .frame(width: proxy.size.width * (fraction ?? 0))
                }
                .compositingGroup()
                .clipShape(.rect(cornerRadius: rounded ? proxy.size.height / 2 : 0, style: .circular))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: fraction)
        }
        .accessibilityHidden(true)
    }
}
