import Foundation
import IOKit.ps

// CFRunLoopSourceInvalidate is safe from any thread, including token destruction.
private final class PowerSourceToken: @unchecked Sendable {
    let source: CFRunLoopSource
    init(_ source: CFRunLoopSource) { self.source = source }
    deinit { CFRunLoopSourceInvalidate(source) }
}

/// Main-run-loop subscription; no assertion is acquired by observing power.
@MainActor public final class AgentAutoContinuePowerObservation {
    private var token: PowerSourceToken?
    private var changed: (@MainActor @Sendable (AgentAutoContinuePower) -> Void)?
    public init() {}
    public func start(_ changed: @escaping @MainActor @Sendable (AgentAutoContinuePower) -> Void) {
        stop(); self.changed = changed
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let observer = Unmanaged<AgentAutoContinuePowerObservation>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { observer.report() }
        }, context)?.takeRetainedValue() else { changed(.unknown); return }
        token = PowerSourceToken(source)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        report()
    }
    public func stop() {
        if let token { CFRunLoopSourceInvalidate(token.source) }
        token = nil; changed = nil
    }
    private func report() { changed?(AgentAutoContinuePowerSource.current()) }
}
