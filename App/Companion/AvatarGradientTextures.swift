import AppKit

@MainActor
enum AvatarGradientTextures {
    static let roomWall = vertical(top: NSColor(srgbRed: 0.55, green: 0.48, blue: 0.72, alpha: 1),
                                   bottom: NSColor(srgbRed: 0.32, green: 0.29, blue: 0.48, alpha: 1))
    static let roomLighting = vertical(top: NSColor(srgbRed: 0.70, green: 0.75, blue: 0.85, alpha: 1),
                                       bottom: NSColor(srgbRed: 0.25, green: 0.22, blue: 0.28, alpha: 1))
    static let dragonLighting = vertical(top: NSColor(srgbRed: 0.82, green: 0.87, blue: 1, alpha: 1),
                                         bottom: NSColor(srgbRed: 0.22, green: 0.24, blue: 0.30, alpha: 1))
    static let standaloneLighting = vertical(top: NSColor(srgbRed: 0.95, green: 0.97, blue: 1, alpha: 1),
                                             bottom: NSColor(srgbRed: 0.08, green: 0.10, blue: 0.18, alpha: 1))
    static let contactShadow = radial(color: .black, opacity: 0.40)

    static func aura(_ color: NSColor) -> NSImage {
        radial(color: color, opacity: 0.82)
    }

    private static func vertical(top: NSColor, bottom: NSColor) -> NSImage {
        let size = NSSize(width: 64, height: 256)
        let colors = (0...12).map { step in
            let progress = CGFloat(step) / 12
            let ease = progress * progress * (3 - 2 * progress)
            return bottom.blended(withFraction: 0.65 * progress + 0.35 * ease, of: top) ?? top
        }
        return NSImage(size: size, flipped: false) { rect in
            NSGradient(colors: colors)?.draw(in: rect, angle: 90)
            return true
        }
    }

    private static func radial(color: NSColor, opacity: CGFloat) -> NSImage {
        let size = NSSize(width: 128, height: 128)
        let colors = (0...12).map { step in
            let radius = CGFloat(step) / 12
            let falloff = 1 - radius * radius * (3 - 2 * radius)
            return color.withAlphaComponent(opacity * falloff * falloff)
        }
        return NSImage(size: size, flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            NSGradient(colors: colors)?.draw(fromCenter: center, radius: 0,
                toCenter: center, radius: min(rect.width, rect.height) / 2, options: [])
            return true
        }
    }
}
