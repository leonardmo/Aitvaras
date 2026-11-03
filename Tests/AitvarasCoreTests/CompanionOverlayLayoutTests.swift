import Foundation
import CoreGraphics
import Testing
@testable import AitvarasCore

@Suite struct CompanionOverlayLayoutTests {
    @Test func independentChatAndSubtitleLayouts() {
        let compact = CompanionOverlayLayout.preferredSize(presentation: .minimal, chatExpanded: false, subtitlesVisible: false)
        let subtitles = CompanionOverlayLayout.preferredSize(presentation: .minimal, chatExpanded: false, subtitlesVisible: true)
        let chat = CompanionOverlayLayout.preferredSize(presentation: .minimal, chatExpanded: true, subtitlesVisible: false)
        let both = CompanionOverlayLayout.preferredSize(presentation: .minimal, chatExpanded: true, subtitlesVisible: true)
        #expect(subtitles.width == compact.width)
        #expect(subtitles.height - compact.height == both.height - chat.height)
        #expect(chat.width > compact.width)
        #expect(chat.height > compact.height)
        #expect(chat == CompanionOverlayLayout.preferredSize(presentation: .avatar, chatExpanded: true, subtitlesVisible: false))
    }

    @Test func expansionAndCollapseKeepLowerRightAnchor() {
        let available = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let compactSize = CompanionOverlayLayout.preferredSize(presentation: .minimal, chatExpanded: false, subtitlesVisible: false)
        let compact = CGRect(origin: CGPoint(x: 1050, y: 24), size: compactSize)
        let expanded = CompanionOverlayLayout.frame(preferredSize: CGSize(width: 460, height: 710), anchoredTo: compact, within: available)
        let restored = CompanionOverlayLayout.frame(preferredSize: compactSize, anchoredTo: expanded, within: available)
        #expect(expanded.maxX == compact.maxX)
        #expect(expanded.minY == compact.minY)
        #expect(restored == compact)
    }

    @Test func expandedLayoutFitsSmallOrOffsetDisplays() {
        let available = CGRect(x: -800, y: 120, width: 400, height: 500)
        let frame = CompanionOverlayLayout.frame(preferredSize: CGSize(width: 460, height: 710),
                                                anchoredTo: CGRect(x: 100, y: -40, width: 360, height: 186), within: available)
        #expect(frame == available)
    }
}
