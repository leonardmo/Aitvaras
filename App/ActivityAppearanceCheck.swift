import AppKit
import SwiftUI
import AitvarasAgents

/// Verifies cached menu artwork without any model, connector, or capture input.
@MainActor enum ActivityAppearanceCheck {
    static func run(path: String) async -> Never {
        var failures: [String] = []
        // The artwork itself, before any code pins it: a source asset that
        // declares a large intrinsic size is the bug this check exists for.
        let artwork = NSImage(named: "DragonMenu")?.size ?? .zero
        if artwork.width > 32 || artwork.height > 32 || artwork.width < 1 {
            failures.append("DragonMenu artwork declares \(Int(artwork.width))x\(Int(artwork.height)); it must declare a menu bar size")
        }
        for style in ActivityGlassStyle.allCases {
            // A status item is sized by its image, so artwork that declares a
            // large intrinsic size would stretch across the whole menu bar.
            let size = DragonActivityMenuLabel.image(for: style).size
            if size.width != DragonActivityMenuLabel.menuSide || size.height != DragonActivityMenuLabel.menuSide {
                failures.append("Menu image is \(Int(size.width))x\(Int(size.height)), not menu bar sized: \(style.rawValue)")
            }
        }
        for style in ActivityGlassStyle.allCases where style != .idle {
            let image = DragonActivityMenuLabel.image(for: style)
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 96, pixelsHigh: 96,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: bitmap) else { exit(1) }
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
            image.draw(in: NSRect(x: 0, y: 0, width: 96, height: 96))
            NSGraphicsContext.restoreGraphicsState()
            var colors = Set<String>()
            var visible = 0
            for y in 0..<96 {
                for x in 0..<96 {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.9 else { continue }
                    visible += 1
                    colors.insert("\(Int(color.redComponent * 31)),\(Int(color.greenComponent * 31)),\(Int(color.blueComponent * 31))")
                }
            }
            if visible < 100 || colors.count < 3 { failures.append("Missing multicolour silhouette: \(style.rawValue)") }
            if (bitmap.colorAt(x: 0, y: 0)?.alphaComponent ?? 1) > 0.01 { failures.append("Gradient escaped silhouette: \(style.rawValue)") }
        }
        let dark = !CommandLine.arguments.contains("--light-fixture")
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        var screenshot: Data?
        appearance?.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content: GradientGallery(dark: dark)
                .environment(\.colorScheme, dark ? .dark : .light))
            renderer.scale = 2
            screenshot = renderer.cgImage.flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }
        }
        do {
            guard let screenshot else { throw CocoaError(.fileWriteUnknown) }
            try screenshot.write(to: URL(fileURLWithPath: path))
        } catch { failures.append("Could not write gradient gallery") }
        for failure in failures { print("[activity-style] FAIL: \(failure)") }
        print(failures.isEmpty ? "[activity-style] PASS: menu bar sizing and cached gradients preserve silhouette transparency" : "[activity-style] FAIL")
        exit(failures.isEmpty ? 0 : 1)
    }
}

/// Uses the production surfaces and textures, with static sample values so
/// the same state appears when comparing the two system appearances.
@MainActor
private struct GradientGallery: View {
    let dark: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Aitvaras gradients").font(.system(size: 28, weight: .semibold))
                Text(dark ? "Dark appearance" : "Light appearance").font(.callout).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Activity tiles and menu bar").font(.headline)
                HStack(spacing: 12) {
                    activity(.idle, title: "Idle", detail: "Ready for work")
                    activity(.working, title: "Working", detail: "Processing a task")
                    activity(.attention, title: "Needs attention", detail: "Waiting for approval")
                    activity(.recording, title: "Recording", detail: "Capture is active")
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Chat meters").font(.headline)
                HStack(spacing: 14) {
                    meter("Available", fiveHours: 0.12, weekly: 0.28, context: 0.48)
                    meter("In use", fiveHours: 0.62, weekly: 0.49, context: 0.77)
                    meter("Near the limit", fiveHours: 0.96, weekly: 0.88, context: 0.97)
                }
            }
            HStack(spacing: 14) {
                labeled("Main window") {
                    WindowGradientBackground().overlay(alignment: .topLeading) {
                        Label("Chat", systemImage: "bubble.left.and.text.bubble.right")
                            .padding(14).font(.callout)
                    }
                }
                labeled("News placeholder") { NewsImagePlaceholder() }
                labeled("Companion glass") {
                    Label("Companion", systemImage: "waveform")
                        .font(.callout)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .neutralGlass(cornerRadius: 12)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Companion scene textures").font(.headline)
                HStack(spacing: 12) {
                    texture("Room wall", AvatarGradientTextures.roomWall)
                    texture("Room lighting", AvatarGradientTextures.roomLighting)
                    texture("Dragon lighting", AvatarGradientTextures.dragonLighting)
                    texture("Standalone lighting", AvatarGradientTextures.standaloneLighting)
                    texture("Contact shadow", AvatarGradientTextures.contactShadow)
                    texture("Mood aura", AvatarGradientTextures.aura(NSColor(srgbRed: 0.36, green: 0.55, blue: 0.96, alpha: 1)))
                }
            }
        }
        .padding(28)
        .frame(width: 940)
        .foregroundStyle(dark ? Color(white: 0.95) : Color(white: 0.12))
        .background(dark ? Color(red: 0.075, green: 0.079, blue: 0.096) : Color(red: 0.969, green: 0.972, blue: 0.982))
    }

    private func activity(_ style: ActivityGlassStyle, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(nsImage: DragonActivityMenuLabel.image(for: style))
                    .renderingMode(style == .idle ? .template : .original)
                    .resizable().scaledToFit().frame(width: 21, height: 21)
                Text(title).font(.callout.weight(.semibold))
            }
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .activityGlass(style: style, cornerRadius: 14)
    }

    private func meter(_ title: String, fiveHours: Double, weekly: Double, context: Double) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.callout.weight(.medium))
            HStack(spacing: 12) {
                ComposerUsageLimits(windows: [
                    .init(id: "five_hour", utilization: fiveHours),
                    .init(id: "seven_day", utilization: weekly)
                ], narrow: false)
                Spacer(minLength: 0)
                ComposerContextMeter(usage: .init(scope: .lastCall, contextTokens: Int(context * 100_000), contextLimit: 100_000),
                                     compact: false)
            }
        }
        .padding(12)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            content()
                .frame(maxWidth: .infinity)
                .frame(height: 100)
                .clipShape(.rect(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.10)) }
        }
    }

    private func texture(_ title: String, _ image: NSImage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(nsImage: image).resizable()
                .frame(maxWidth: .infinity)
                .frame(height: 72)
                .background(dark ? Color(white: 0.15) : Color(white: 0.91))
                .clipShape(.rect(cornerRadius: 8))
            Text(title).font(.caption).lineLimit(1)
        }
    }
}
