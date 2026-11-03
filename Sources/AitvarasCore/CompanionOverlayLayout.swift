import Foundation
import CoreGraphics

/// Presentation geometry only: work never reveals or expands the companion.
public enum CompanionOverlayLayout {
    public static func preferredSize(presentation: CompanionPresentation, chatExpanded: Bool, subtitlesVisible: Bool) -> CGSize {
        let width: CGFloat = chatExpanded ? 460 : 360
        let baseHeight: CGFloat = chatExpanded ? 600 : (presentation.usesAvatar ? 414 : 186)
        return CGSize(width: width, height: baseHeight + (subtitlesVisible ? 110 : 0))
    }

    /// Keep the lower-right anchor and clamp size as well as position.
    public static func frame(preferredSize: CGSize, anchoredTo old: CGRect, within available: CGRect) -> CGRect {
        let size = CGSize(width: min(preferredSize.width, available.size.width), height: min(preferredSize.height, available.size.height))
        return CGRect(x: min(max(old.maxX - size.width, available.minX), available.maxX - size.width),
                      y: min(max(old.minY, available.minY), available.maxY - size.height),
                      width: size.width, height: size.height)
    }
}
