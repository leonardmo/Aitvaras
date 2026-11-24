import SwiftUI

/// Samples a quadratic color curve so adjoining shades have a continuous
/// transition. SwiftUI surfaces and AppKit artwork use the same sRGB stops.
struct ColorRamp {
    private let start: SIMD3<Double>
    private let control: SIMD3<Double>
    private let end: SIMD3<Double>

    init(_ start: UInt32, _ control: UInt32, _ end: UInt32) {
        self.init(start: Self.rgb(start), control: Self.rgb(control), end: Self.rgb(end))
    }

    private init(start: SIMD3<Double>, control: SIMD3<Double>, end: SIMD3<Double>) {
        self.start = start
        self.control = control
        self.end = end
    }

    private static func rgb(_ hex: UInt32) -> SIMD3<Double> {
        SIMD3(Double((hex >> 16) & 255), Double((hex >> 8) & 255), Double(hex & 255)) / 255
    }

    private func components(at t: Double) -> SIMD3<Double> {
        let u = 1 - t
        return start * (u * u) + control * (2 * u * t) + end * (t * t)
    }

    func color(at t: Double) -> Color {
        let value = components(at: t)
        return Color(.sRGB, red: value.x, green: value.y, blue: value.z)
    }

    func mixed(with next: Self, by t: Double) -> Self {
        Self(start: start + (next.start - start) * t,
             control: control + (next.control - control) * t,
             end: end + (next.end - end) * t)
    }

    func wash(opacity: Double = 1, from start: UnitPoint = .topLeading, to end: UnitPoint = .bottomTrailing) -> LinearGradient {
        LinearGradient(colors: (0...12).map { color(at: Double($0) / 12).opacity(opacity) },
                       startPoint: start, endPoint: end)
    }

    var nativeColors: [NSColor] {
        (0...12).map { step in
            let value = components(at: Double(step) / 12)
            return NSColor(srgbRed: value.x, green: value.y, blue: value.z, alpha: 1)
        }
    }

    static let idle = Self(0x397ED9, 0x5261F2, 0x9C63E0)
    static let working = Self(0x286DDB, 0x9A4DF4, 0xF47954)
    static let attention = Self(0xFFCB6A, 0xF3923D, 0xDB5957)
    static let recording = Self(0xF062A6, 0xE42E77, 0xF46A50)
    static let news = Self(0x368DDE, 0x6557EF, 0xBA6EDB)

    private static let lowUsage = Self(0x31BD9B, 0x36AE70, 0xA3D763)
    private static let elevatedUsage = Self(0xF6C75E, 0xF89B44, 0xD57B46)

    static func usage(_ fraction: Double) -> Self {
        if fraction < 0.65 {
            let t = min(1, max(0, (fraction - 0.18) / 0.47))
            return lowUsage.mixed(with: elevatedUsage, by: t * t * (3 - 2 * t))
        }
        let t = min(1, (fraction - 0.65) / 0.35)
        return elevatedUsage.mixed(with: recording, by: t * t * (3 - 2 * t))
    }
}

struct GradientTileSurface: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let ramp: ColorRamp
    let cornerRadius: CGFloat
    var prominent = false

    var body: some View {
        let dark = colorScheme == .dark
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if contrast == .increased || reduceTransparency {
            shape.fill(Color(nsColor: .windowBackgroundColor))
                .overlay { shape.strokeBorder(Color.primary.opacity(0.52), lineWidth: 1) }
        } else {
            let strength = prominent ? (dark ? 0.54 : 0.24) : (dark ? 0.40 : 0.18)
            shape.fill(ramp.wash(opacity: strength))
                .overlay {
                    shape.fill(LinearGradient(colors: [
                        .white.opacity(dark ? 0.12 : 0.42),
                        .white.opacity(dark ? 0.025 : 0.07),
                        .white.opacity(0)
                    ], startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                .overlay {
                    shape.strokeBorder(ramp.wash(opacity: dark ? 0.58 : 0.33), lineWidth: 1)
                }
        }
    }
}

struct WindowGradientBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if contrast != .increased {
                LinearGradient(colors: [
                    ColorRamp.idle.color(at: 0).opacity(colorScheme == .dark ? 0.14 : 0.08),
                    ColorRamp.idle.color(at: 1).opacity(colorScheme == .dark ? 0.055 : 0.023),
                    ColorRamp.idle.color(at: 1).opacity(0)
                ], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
    }
}
