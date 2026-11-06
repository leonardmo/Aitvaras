import SwiftUI
import AppKit

@main
struct AitvarasApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Aitvaras", id: "main") {
            MainWindow()
                .environment(AppModel.shared)
                .frame(minWidth: 800, maxWidth: .infinity, minHeight: 500, maxHeight: .infinity, alignment: .topLeading)
                .overlay {
                    if UIShot.requestedPath != nil, CommandLine.arguments.contains("--single-window-check") {
                        SingleMainWindowProbe()
                    }
                }
                .task {
                    // Diagnostic modes own their lifecycle and must not race a
                    // second, normal bootstrap against the same temporary DB.
                    #if DEBUG
                    guard !SelfDriver.requested else { return }
                    #endif
                    guard !SelfTest.requested,
                          AvatarShot.requestedPath == nil,
                          AvatarShot.liveshotPath == nil,
                          AvatarEfficiencyCheck.requestedPath == nil,
                          !VoiceTest.requested,
                          FileTranscribe.requestedPath == nil,
                          UIShot.requestedPath == nil else { return }
                    await AppModel.shared.bootstrapIfNeeded()
                    // If the app restarted after will-sleep but before it saw
                    // did-wake, the durable boundary still deserves a recap.
                    await AppModel.shared.handleSystemWake()
                }
        }
        .defaultSize(width: 1080, height: 720)
        #if DEBUG
        .defaultLaunchBehavior(SelfDriver.requested ? .suppressed : .presented)
        #else
        .defaultLaunchBehavior(.presented)
        #endif
        .commands {
            CommandGroup(after: .appVisibility) {
                Button("Toggle Companion") {
                    appDelegate.toggleCompanion()
                }
                .keyboardShortcut(.space, modifiers: .option)
            }
        }
        Settings {
            SettingsWorkspaceView(initialRoute: .setup).environment(AppModel.shared)
                .frame(width: 820, height: 680)
        }
        MenuBarExtra {
            VStack(spacing: 0) {
                ActivityMenuView().environment(AppModel.shared)
                Divider()
                ActivityMenuControls()
            }
        } label: {
            DragonActivityMenuLabel().environment(AppModel.shared)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var companion: CompanionPanelController?
    private var hotkey: HotkeyManager?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var wakeBriefingTask: Task<Void, Never>?
    private var wakeBriefingPending = false
    private var terminationPending = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if SelfDriver.requested { SelfDriver.prepareLaunch() }
        #endif
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if SelfDriver.requested {
            Task { await SelfDriver.run() }
            return
        }
        #endif
        // Set the running app's Dock icon from the bundled artwork as well as
        // its Info.plist, avoiding a stale generic icon after local updates.
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        if let path = AvatarEfficiencyCheck.requestedPath {
            Task { await AvatarEfficiencyCheck.run(path: path) }
            return
        }
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
        if let shotPath = UIShot.requestedPath {
            Task { await UIShot.run(path: shotPath) }
            return
        }
        AppAppearance.shared.apply()
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
            Task { @MainActor [weak self] in
                self?.companion?.show()
            }
        }

        observeSystemSleepAndWake()

        companion.show()
    }

    private func observeSystemSleepAndWake() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Delivery is explicitly on OperationQueue.main. Persist before
            // returning from willSleep; an asynchronously scheduled Task may
            // not run before macOS suspends the process.
            MainActor.assumeIsolated {
                self?.wakeBriefingTask?.cancel()
                self?.wakeBriefingTask = nil
                self?.wakeBriefingPending = false
                AppModel.shared.noteSystemWillSleep()
            }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                AppModel.shared.noteNightlySchedulingOpportunity()
                self?.wakeBriefingPending = true
                // A device wake can be a background maintenance wake. Wait
                // for a screen/session signal before presenting anything.
            }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard self?.wakeBriefingPending == true else { return }
                // Give Mail and Notification Center a moment to become
                // queryable. A session-active signal can shorten this delay.
                self?.scheduleWakeBriefing(after: .seconds(8))
            }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard self?.wakeBriefingPending == true else { return }
                self?.scheduleWakeBriefing(after: .seconds(2))
            }
        })
    }

    private func scheduleWakeBriefing(after delay: Duration) {
        wakeBriefingTask?.cancel()
        wakeBriefingTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) }
            catch { return }
            guard let self, wakeBriefingPending else { return }
            wakeBriefingPending = false
            wakeBriefingTask = nil
            await AppModel.shared.handleSystemWake()
        }
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
        false   // application-owned chats and the companion keep running
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        Task {
            do {
                // Journal interruption and detach chat generations before
                // waiting for unrelated installers or legacy operations.
                try await AppModel.shared.shutdownAgentChats()
                await AppModel.shared.nativeWorkspace.operations.stopBeforeTermination()
                await AppModel.shared.shutdownMonitoring()
                await AppModel.shared.captureRefinement.stopBeforeTermination()
                AppModel.shared.modelDownloads.cancelActive()
                AppModel.shared.neuralVoiceInstaller.cancelActive()
                await AppModel.shared.modelDownloads.stopBeforeTermination()
                await AppModel.shared.neuralVoiceInstaller.stopBeforeTermination()
                await SpeechAssetReadiness.shared.stopBeforeTermination(reporter: AppModel.shared.activityReporter)
                try await AppModel.shared.capture?.stopBeforeTermination()
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                terminationPending = false
                AppModel.shared.chatModel?.resumeAfterCancelledTermination()
                AppModel.shared.nativeWorkspace.operations.resumeAfterCancelledTermination()
                CaptureWindows.shared.showSaveError(error)
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        wakeBriefingTask?.cancel()
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            workspaceCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        // The open chat would otherwise vanish unlearned; the flush is
        // best-effort — termination won't wait for a slow model.
        // Conversations are already durable; quitting never starts new inference.
        AppModel.shared.stopNewsScheduler()
        AppModel.shared.stopNightlyConsolidationScheduler()
        AppModel.shared.modelDownloads.cancelActive()
        AppModel.shared.neuralVoiceInstaller.cancelActive()
        // Don't leave a sidecar zombie serving future app versions.
        AppModel.shared.neuralTTS?.shutdownServer()
    }
}
