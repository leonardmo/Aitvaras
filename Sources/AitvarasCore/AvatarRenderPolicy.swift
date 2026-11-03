/// Pure companion rendering policy. App activation is intentionally absent:
/// a floating companion is still visible while the user works in another app.
public enum AvatarRenderPolicy {
    public struct Visibility: Equatable, Sendable {
        public var isAttached = false
        public var isViewHidden = false
        public var isWindowVisible = false
        public var isWindowMiniaturized = false
        public var isWindowOccluded = true
        public var isAppHidden = false
        public var isDisplaySleeping = false
        public var isSystemSleeping = false

        public init() {}

        public var canRender: Bool {
            isAttached && !isViewHidden && isWindowVisible
                && !isWindowMiniaturized && !isWindowOccluded && !isAppHidden
                && !isDisplaySleeping && !isSystemSleeping
        }
    }

    public enum Mode: Equatable, Sendable {
        case suspended
        case onDemand
        case animated
    }

    public struct Decision: Equatable, Sendable {
        public let mode: Mode
        /// Zero means no continuous render loop, not an uncapped display rate.
        public let framesPerSecond: Int
        public var allowsVisualTasks: Bool { mode != .suspended }
    }

    public static func decision(
        visibility: Visibility,
        state: CharacterState,
        hasTransientAnimation: Bool
    ) -> Decision {
        guard visibility.canRender else {
            return Decision(mode: .suspended, framesPerSecond: 0)
        }
        if state != .idle || hasTransientAnimation {
            return Decision(mode: .animated, framesPerSecond: 30)
        }
        return Decision(mode: .onDemand, framesPerSecond: 0)
    }
}
