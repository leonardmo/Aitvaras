import SwiftUI
import AppKit

@main
struct AitvarasApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Aitvaras", id: "main") {
            MainWindow()
                .environment(AppModel.shared)
                .frame(minWidth: 900, minHeight: 600)
                .task { await AppModel.shared.bootstrapIfNeeded() }
        }
        .defaultSize(width: 1080, height: 720)
        .commands {
            CommandGroup(after: .appVisibility) {
                Button("Toggle Companion \u{2325}Space") {
                    appDelegate.toggleCompanion()
                }
                .keyboardShortcut(.space, modifiers: .option)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var companion: CompanionPanelController?
    private var hotkey: HotkeyManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if SelfTest.requested {
            Task.detached { await SelfTest.run() }
            return
        }
        if let shotPath = AvatarShot.requestedPath {
            Task { await AvatarShot.run(path: shotPath) }
            return
        }
        if let livePath = AvatarShot.liveshotPath {
            Task { await AvatarShot.runLive(path: livePath) }
            return
        }
        if VoiceTest.requested {
            Task { await VoiceTest.run() }
            return
        }
        if let transcribePath = FileTranscribe.requestedPath {
            Task { await FileTranscribe.run(path: transcribePath) }
            return
        }
        let companion = CompanionPanelController(model: AppModel.shared)
        self.companion = companion

        // Global ⌥Space (works while other apps are frontmost):
        // tap = show/hide companion, hold 1s = show + start voice.
        hotkey = HotkeyManager(
            onTap: { [weak self] in
                self?.toggleCompanion()
            },
            onHold: { [weak self] in
                self?.companion?.show()
                AppModel.shared.startVoiceViaHotkey()
            },
            onDoubleTap: { [weak self] in
                self?.companion?.showForTyping()
                AppModel.shared.companionFocusRequest += 1
            })

        // Proactive moments (breaks, drift, urgent messages) bring her
        // on screen instead of firing a system notification.
        NotificationCenter.default.addObserver(
            forName: .aitvarasShowCompanion, object: nil, queue: .main
        ) { [weak self] _ in
            self?.companion?.show()
        }

        companion.show()
    }

    func toggleCompanion() {
        guard let companion else { return }
        if companion.isVisible {
            // Hiding her also ends the conversation — no invisible hot mic.
            if AppModel.shared.voiceEnabled {
                AppModel.shared.toggleVoice()
            }
            companion.hide()
        } else {
            companion.show()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false   // companion keeps living in the corner
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The open chat would otherwise vanish unlearned; the flush is
        // best-effort — termination won't wait for a slow model.
        AppModel.shared.archiveCurrentChat()
        // Don't leave a sidecar zombie serving future app versions.
        AppModel.shared.neuralTTS?.shutdownServer()
    }
}
