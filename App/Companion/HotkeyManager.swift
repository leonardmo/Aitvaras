import AppKit
import Carbon.HIToolbox

/// Global ⌥Space hotkey via Carbon — works system-wide without
/// accessibility permission. Two gestures:
/// - tap: toggle the companion window
/// - hold: show the companion AND start voice interaction
/// @unchecked Sendable: Carbon delivers events on the main event loop.
final class HotkeyManager: @unchecked Sendable {
    /// Tap/hold boundary. Real taps land well under 250ms; 400ms feels
    /// immediate as a hold without misreading slow taps.
    private static let holdThreshold: TimeInterval = 0.4
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    /// Two taps within this window = double-tap (typed-prompt mode).
    private static let doubleTapWindow: TimeInterval = 0.35

    private let onTap: () -> Void
    private let onHold: () -> Void
    private let onDoubleTap: () -> Void
    private var holdWork: DispatchWorkItem?
    private var holdTriggered = false
    private var isDown = false
    private var lastTapAt: Date = .distantPast

    init(onTap: @escaping () -> Void,
         onHold: @escaping () -> Void,
         onDoubleTap: @escaping () -> Void) {
        self.onTap = onTap
        self.onHold = onHold
        self.onDoubleTap = onDoubleTap
        register()
    }

    private func register() {
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyReleased))
        ]

        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData, let event else { return noErr }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                let kind = GetEventKind(event)
                DispatchQueue.main.async {
                    if kind == UInt32(kEventHotKeyPressed) {
                        manager.keyDown()
                    } else if kind == UInt32(kEventHotKeyReleased) {
                        manager.keyUp()
                    }
                }
                return noErr
            },
            2, &eventTypes, selfPointer, &eventHandler)

        let hotKeyID = EventHotKeyID(signature: OSType(0x4E414F4D), id: 1)   // 'NAOM'
        RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef)
    }

    private func keyDown() {
        guard !isDown else { return }   // key-repeat delivers extra presses
        isDown = true
        holdTriggered = false
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isDown else { return }
            self.holdTriggered = true
            self.onHold()
        }
        holdWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdThreshold, execute: work)
    }

    private func keyUp() {
        isDown = false
        holdWork?.cancel()
        holdWork = nil
        if !holdTriggered {
            // First tap acts immediately (show/hide stays snappy); a
            // second tap inside the window upgrades to typed-prompt mode.
            if Date.now.timeIntervalSince(lastTapAt) < Self.doubleTapWindow {
                onDoubleTap()
            } else {
                onTap()
            }
            lastTapAt = .now
        }
        holdTriggered = false
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
