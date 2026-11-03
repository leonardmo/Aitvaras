import AppKit
import CoreGraphics
import AitvarasCore

/// Notification-driven visibility tracking: no polling, and no dependence on
/// key-window or application activation (the companion is a floating window).
@MainActor
final class AvatarRenderLifecycle: NSObject {
    private weak var view: NSView?
    private let workspaceCenter = NSWorkspace.shared.notificationCenter
    private var displaySleeping = false
    private var systemSleeping = false
    private weak var closingWindow: NSWindow?
    private var lastVisibility: AvatarRenderPolicy.Visibility?
    var onChange: ((AvatarRenderPolicy.Visibility) -> Void)?

    func attach(to view: NSView) {
        stop()
        self.view = view
        systemSleeping = false
        displaySleeping = CGDisplayIsAsleep(CGMainDisplayID()) != 0
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification,
                     NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification,
                     NSWindow.didChangeScreenNotification,
                     NSApplication.didHideNotification,
                     NSApplication.didUnhideNotification] {
            center.addObserver(self, selector: #selector(refreshFromNotification), name: name, object: nil)
        }
        center.addObserver(self, selector: #selector(windowWillClose), name: NSWindow.willCloseNotification, object: nil)
        let workspace = workspaceCenter
        workspace.addObserver(self, selector: #selector(displayWillSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(displayDidWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(systemWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil)
        refresh()
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        workspaceCenter.removeObserver(self)
        view = nil
        closingWindow = nil
        lastVisibility = nil
    }

    func refresh() {
        var visibility = AvatarRenderPolicy.Visibility()
        if let view {
            let window = view.window
            visibility.isAttached = window != nil && view.superview != nil
            visibility.isViewHidden = view.isHiddenOrHasHiddenAncestor
            visibility.isWindowVisible = window?.isVisible == true && window !== closingWindow
            visibility.isWindowMiniaturized = window?.isMiniaturized == true
            visibility.isWindowOccluded = window?.occlusionState.contains(.visible) != true
        }
        visibility.isAppHidden = NSApp.isHidden
        visibility.isDisplaySleeping = displaySleeping
        visibility.isSystemSleeping = systemSleeping
        guard visibility != lastVisibility else { return }
        lastVisibility = visibility
        onChange?(visibility)
    }

    @objc private func refreshFromNotification(_ notification: Notification) { refresh() }
    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === view?.window else { return }
        closingWindow = window
        refresh()
    }
    @objc private func displayWillSleep(_ notification: Notification) { displaySleeping = true; refresh() }
    @objc private func displayDidWake(_ notification: Notification) { displaySleeping = false; refresh() }
    @objc private func systemWillSleep(_ notification: Notification) { systemSleeping = true; refresh() }
    @objc private func systemDidWake(_ notification: Notification) { systemSleeping = false; refresh() }

    deinit {
        NotificationCenter.default.removeObserver(self)
        workspaceCenter.removeObserver(self)
    }
}
