import AppKit
import SwiftUI

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
        let preview = HStack(spacing: 20) {
            ForEach(ActivityGlassStyle.allCases, id: \.rawValue) { style in
                VStack(spacing: 12) {
                    Image(nsImage: DragonActivityMenuLabel.image(for: style)).resizable().scaledToFit().frame(width: 80, height: 80)
                    Text(style.rawValue.capitalized).font(.caption.weight(.semibold))
                }
                .padding(22).activityGlass(style: style)
            }
        }.padding(24).background(Color(nsColor: .windowBackgroundColor))
        let renderer = ImageRenderer(content: preview)
        renderer.scale = 2
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff), let data = bitmap.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        for failure in failures { print("[activity-style] FAIL: \(failure)") }
        print(failures.isEmpty ? "[activity-style] PASS: menu bar sizing and cached gradients preserve silhouette transparency" : "[activity-style] FAIL")
        exit(failures.isEmpty ? 0 : 1)
    }
}
