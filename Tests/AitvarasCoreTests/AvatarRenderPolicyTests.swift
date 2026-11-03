import Testing
@testable import AitvarasCore

@Suite struct AvatarRenderPolicyTests {
    private var visible: AvatarRenderPolicy.Visibility {
        var value = AvatarRenderPolicy.Visibility()
        value.isAttached = true
        value.isWindowVisible = true
        value.isWindowOccluded = false
        return value
    }

    @Test func idleUsesNoContinuousFrames() {
        let result = AvatarRenderPolicy.decision(visibility: visible, state: .idle, hasTransientAnimation: false)
        #expect(result.mode == .onDemand)
        #expect(result.framesPerSecond == 0)
        #expect(result.allowsVisualTasks)
    }

    @Test func conversationalStatesAreCapped() {
        for state in [CharacterState.listening, .thinking, .speaking] {
            let result = AvatarRenderPolicy.decision(visibility: visible, state: state, hasTransientAnimation: false)
            #expect(result.mode == .animated)
            #expect(result.framesPerSecond == 30)
        }
    }

    @Test func blinkBurstReturnsToOnDemand() {
        #expect(AvatarRenderPolicy.decision(visibility: visible, state: .idle, hasTransientAnimation: true).mode == .animated)
        #expect(AvatarRenderPolicy.decision(visibility: visible, state: .idle, hasTransientAnimation: false).mode == .onDemand)
    }

    @Test func everyVisibilityBlockerSuppressesEvenActiveAnimation() {
        let blockers: [WritableKeyPath<AvatarRenderPolicy.Visibility, Bool>] = [
            \.isViewHidden, \.isWindowMiniaturized, \.isWindowOccluded,
            \.isAppHidden, \.isDisplaySleeping, \.isSystemSleeping
        ]
        var cases = blockers.map { keyPath in
            var value = visible
            value[keyPath: keyPath] = true
            return value
        }
        var detached = visible
        detached.isAttached = false
        cases.append(detached)
        var orderedOut = visible
        orderedOut.isWindowVisible = false
        cases.append(orderedOut)
        cases.append(.init())
        for visibility in cases {
            for state in [CharacterState.idle, .listening, .thinking, .speaking] {
                let result = AvatarRenderPolicy.decision(visibility: visibility, state: state, hasTransientAnimation: true)
                #expect(result.mode == .suspended)
                #expect(result.framesPerSecond == 0)
                #expect(!result.allowsVisualTasks)
            }
        }
    }

    @Test func wakeDoesNotOverrideOtherVisibilityBlockers() {
        var visibility = visible
        visibility.isSystemSleeping = true
        visibility.isDisplaySleeping = true
        visibility.isWindowMiniaturized = true
        visibility.isSystemSleeping = false
        visibility.isDisplaySleeping = false
        #expect(!visibility.canRender)
        visibility.isWindowMiniaturized = false
        #expect(AvatarRenderPolicy.decision(visibility: visibility, state: .speaking, hasTransientAnimation: false).mode == .animated)
    }
}
