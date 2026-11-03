import Foundation
import AppKit
import SwiftUI
import AitvarasCore

@MainActor enum SidebarLayoutProbe { static var frames: [String: CGRect] = [:] }

/// In-process screenshot seam for native SwiftUI windows. Unlike macOS screen
/// capture this needs no Screen Recording permission and therefore works in
/// automated isolated-profile QA.
enum UIShot {
    static var requestedPath: String? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["AITVARAS_UI_TEST_MODE"] == "1",
              environment["AITVARAS_STATE_DIR"]?.isEmpty == false else { return nil }
        guard let index = CommandLine.arguments.firstIndex(of: "--uishot"),
              CommandLine.arguments.count > index + 1 else { return nil }
        return CommandLine.arguments[index + 1]
    }

    @MainActor
    static func run(path: String) async -> Never {
        if CommandLine.arguments.contains("--sidebar-window-check") {
            do { try WorkspaceCheck.prepareAndCheck(AppModel.shared, scenario: "primary") }
            catch { print("[sidebar-check] FAIL: fixture unavailable"); exit(1) }
            try? await Task.sleep(for: .seconds(1))
            guard let window = NSApp.windows.first(where: {
                $0.toolbar?.items.contains(where: { $0.itemIdentifier.rawValue == "aitvaras.sidebarToggle" }) == true
            }), let item = window.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == "aitvaras.sidebarToggle" }),
                let view = item.view, !view.isHidden, view.frame.width > 0 else {
                print("[sidebar-check] FAIL: window-level toggle unavailable"); exit(1)
            }
            let state = CommandLine.arguments.contains("--hide-sidebar-fixture") ? "hidden" : "shown"
            if state == "shown" {
                for placement in ActivityDockPlacement.allCases {
                    NotificationCenter.default.post(name: Notification.Name("aitvaras.sidebarCheckDock"), object: placement)
                    for size in [NSSize(width: 900, height: 720), NSSize(width: 1080, height: 720),
                                 NSSize(width: 1600, height: 720), NSSize(width: 900, height: 1600)] {
                        window.setContentSize(size)
                        for route in [SidebarItem.chat, .capture, .today, .chat, .activity, .library, .setup] {
                            NotificationCenter.default.post(name: Notification.Name("aitvaras.sidebarCheckRoute"), object: route.rawValue)
                            try? await Task.sleep(for: .milliseconds(150))
                            let expected: CGFloat = route == .chat ? 246 : 50
                            guard let sidebar = SidebarLayoutProbe.frames["sidebar"], abs(sidebar.width - expected) < 1,
                                  let icons = SidebarLayoutProbe.frames["icons"], abs(icons.width - 50) < 1,
                                  abs(icons.minX) < 1,
                                  let button = SidebarLayoutProbe.frames["button-\(SidebarItem.chat.rawValue)"],
                                  abs(button.midX - 25) < 1,
                                  let root = SidebarLayoutProbe.frames["root"], abs(root.minX) < 1,
                                  abs(root.width - window.contentView!.bounds.width) < 1 else {
                                print("[sidebar-check] geometry: \(SidebarLayoutProbe.frames)")
                                print("[sidebar-check] FAIL: navigation displaced at size \(size), dock \(placement), section \(route)"); exit(1)
                            }
                            if route == .chat {
                                guard let projects = SidebarLayoutProbe.frames["projects"],
                                      abs(projects.minX - 51) < 1, abs(projects.width - 195) < 1 else {
                                    print("[sidebar-check] FAIL: project rail displaced: \(SidebarLayoutProbe.frames)"); exit(1)
                                }
                            }
                        }
                    }
                }
            }
            print("[sidebar-check] PASS: window-level toggle mounted; sidebar \(state); populated rail positions checked across 84 size/dock/section combinations when shown")
            exit(0)
        }
        if CommandLine.arguments.contains("--codex-ui-fixture") {
            do { try await CodexWorkspaceCheck.prepareUI(AppModel.shared) }
            catch { print("[codex-ui-check] FAIL: synthetic fixture failed"); exit(1) }
            await renderMonitoring(path: path)
        }
        if CommandLine.arguments.contains("--claude-ui-fixture") {
            do { try await ClaudeWorkspaceCheck.prepareUI(AppModel.shared) }
            catch { print("[claude-ui-check] FAIL: synthetic fixture failed"); exit(1) }
            await renderMonitoring(path: path)
        }
        if CommandLine.arguments.contains("--claude-workspace-check") {
            do { try await ClaudeWorkspaceCheck.run(); exit(0) }
            catch { print("[claude-workspace-check] FAIL: \(error)"); exit(1) }
        }
        if CommandLine.arguments.contains("--codex-workspace-check") {
            do { try await CodexWorkspaceCheck.run(); exit(0) }
            catch { print("[codex-workspace-check] FAIL: synthetic integration check failed (\(error))"); exit(1) }
        }
        if CommandLine.arguments.contains("--codex-native-workspace-check") {
            do { try await CodexNativeWorkspaceCheck.run(); exit(0) }
            catch { print("[codex-native-workspace-check] FAIL: \(error)"); exit(1) }
        }
        if CommandLine.arguments.contains("--capture-sleep-native-check") {
            do {
                let driver = NativeCaptureSleepAssertionDriver()
                for policy in [CaptureSleepProtectionPolicy.audioOnly, .visualEvidence] {
                    let lease = try CaptureSleepProtectionLease(policy: policy, driver: driver)
                    lease.release()
                }
                print("[capture-sleep-native-check] PASS: native idle-system/display assertions acquired and released; no inputs opened")
                exit(0)
            } catch {
                print("[capture-sleep-native-check] FAIL: native power assertion unavailable")
                exit(1)
            }
        }
        if CommandLine.arguments.contains("--appearance-check") {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 160),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = NSHostingView(rootView: Text("Synthetic appearance check"))
            window.makeKeyAndOrderFront(nil)
            for mode in [AitvarasCore.AppAppearanceMode.dark, .light, .system] {
                AppAppearance.shared.select(mode)
                // Native appearance inheritance is delivered on the AppKit
                // run loop; a synchronous read can see the previous mode.
                try? await Task.sleep(for: .milliseconds(100))
                guard AppAppearanceMode.load() == mode else { print("[appearance-check] FAIL: preference not retained"); exit(1) }
                let name = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
                guard mode == .system ? NSApp.appearance == nil && window.appearance == nil : name == (mode == .dark ? .darkAqua : .aqua) else {
                    print("[appearance-check] FAIL: mode=\(mode.rawValue), effective=\(name?.rawValue ?? "none"), app=\(NSApp.appearance?.name.rawValue ?? "system"), window=\(window.appearance?.name.rawValue ?? "inherited")"); exit(1)
                }
            }
            print("[appearance-check] PASS: light/dark window inheritance, preference persistence and System reset")
            exit(0)
        }
        if CommandLine.arguments.contains("--native-history-fixes-check") {
            do { try await NativeHistoryFixCheck.run(AppModel.shared); exit(0) }
            catch { print("[native-history-fixes] FAIL: synthetic integration check failed"); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--workspace-fixture") {
            let scenario = CommandLine.arguments.dropFirst(index + 1).first ?? "primary"
            do { try WorkspaceCheck.prepareAndCheck(AppModel.shared, scenario: scenario) }
            catch { print("[workspace-check] FAIL: \(error.localizedDescription)"); exit(1) }
            await renderMonitoring(path: path)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--capture-refinement-check"),
           CommandLine.arguments.count > index + 1 {
            do {
                _ = try await CaptureRefinementCheck.runAndWrite(
                    audioURL: URL(fileURLWithPath: CommandLine.arguments[index + 1]),
                    outputDirectory: URL(fileURLWithPath: path).deletingLastPathComponent(),
                    language: CommandLine.arguments.contains("--german-speech-fixture") ? .german : .english,
                    includeMicrophone: CommandLine.arguments.contains("--two-source-fixture"))
                print("[refinement-check] PASS: both local models produced separate source-timed candidates")
                exit(0)
            } catch {
                print("[refinement-check] FAIL: inspect the closed-metadata diagnostic report")
                exit(1)
            }
        }
        if CommandLine.arguments.contains("--activity-style-check") {
            await ActivityAppearanceCheck.run(path: path)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--speech-stop-check"),
           CommandLine.arguments.count > index + 1 {
            await CaptureSpeechCheck.run(path: CommandLine.arguments[index + 1])
        }
        if CommandLine.arguments.contains("--capture-lifecycle-check") {
            do {
                try AppModel.shared.prepareMonitoringFixture("idle")
                try AppModel.shared.prepareSyntheticCapturePreview()
                guard let capture = AppModel.shared.capture else { exit(1) }
                try await capture.runSyntheticStopChecks()
                print("[capture-check] PASS: stalled OCR, final buffer drain, late-result isolation, save failure and retry")
                exit(0)
            } catch {
                print("[capture-check] FAIL: \(error.localizedDescription)")
                exit(1)
            }
        }
        if CommandLine.arguments.contains("--capture-audio-lifecycle-check") {
            do {
                try AppModel.shared.prepareMonitoringFixture("idle")
                try AppModel.shared.prepareSyntheticCapturePreview()
                guard let capture = AppModel.shared.capture else { exit(1) }
                try await capture.runSyntheticAudioChecks()
                print("[capture-audio-check] PASS: optional retained sources, text durability, explicit deletion and discard default")
                exit(0)
            } catch {
                print("[capture-audio-check] FAIL: \(error.localizedDescription)")
                exit(1)
            }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--companion-ui-fixture") {
            let options = ["compact", "subtitles", "chat"]
            let next = CommandLine.arguments.dropFirst(index + 1).first
            let fixture = next.flatMap { options.contains($0) ? $0 : nil } ?? "compact"
            do {
                try AppModel.shared.prepareMonitoringFixture("active")
                try AppModel.shared.prepareSyntheticCapturePreview()
            } catch {
                print("[uishot] FAIL: synthetic companion fixture could not be created")
                exit(1)
            }
            await renderCompanionFixture(path: path, fixture: fixture)
        }
        if CommandLine.arguments.contains("--single-window-check") {
            try? await Task.sleep(for: .seconds(2))
            // navigationTitle changes the native title (e.g. Home/History),
            // so identify the main scene by its minimum workspace size.
            let count = NSApp.windows.filter { $0.canBecomeKey && $0.frame.width >= 900 && $0.frame.height >= 600 }.count
            guard count == 1 else { print("[uishot] FAIL: expected one main window, found \(count)"); exit(1) }
            print("[uishot] single main window retained after repeated open requests")
            exit(0)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--monitoring-fixture"),
           CommandLine.arguments.count > index + 1 {
            if let placement = CommandLine.arguments.firstIndex(of: "--dock-placement"),
               CommandLine.arguments.count > placement + 1,
               let value = ActivityDockPlacement(rawValue: CommandLine.arguments[placement + 1]) { value.save() }
            do { try AppModel.shared.prepareMonitoringFixture(CommandLine.arguments[index + 1]) }
            catch { print("[uishot] FAIL: monitoring fixture could not be created"); exit(1) }
            await renderMonitoring(path: path)
        }
        if CommandLine.arguments.contains("--open-companion") {
            await renderCompanion(path: path)
        }
        if CommandLine.arguments.contains("--open-setup") {
            await renderSetup(path: path)
        }
        await AppModel.shared.bootstrapIfNeeded()
        try? await Task.sleep(for: .seconds(5))

        // `cacheDisplay` cannot reliably capture SwiftUI ScrollView content
        // while the test app is offscreen. Render this review-first surface
        // directly so agent-driven visual QA sees the real SwiftUI hierarchy.
        if CommandLine.arguments.contains("--open-shortcuts") {
            let renderer = ImageRenderer(content:
                CommandRoutinesView(model: AppModel.shared).snapshotContent
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 900, height: 720, alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor)))
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let data = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: data),
                  let png = bitmap.representation(using: .png, properties: [:])
            else {
                print("[uishot] FAIL: could not render Shortcuts")
                exit(1)
            }
            do {
                try png.write(to: URL(fileURLWithPath: path))
                print("[uishot] wrote \(path)")
                exit(0)
            } catch {
                print("[uishot] FAIL: \(error.localizedDescription)")
                exit(1)
            }
        }

        let candidates = NSApp.windows.filter { $0.contentView != nil && $0.frame.width >= 700 }
        guard let window = candidates.max(by: { $0.frame.width < $1.frame.width }),
              let view = window.contentView else {
            for window in NSApp.windows {
                print("[uishot] window '\(window.title)' \(Int(window.frame.width))x\(Int(window.frame.height))")
            }
            print("[uishot] FAIL: main window not found")
            exit(1)
        }
        window.setContentSize(NSSize(width: 1080, height: 720))
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard let representation = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            print("[uishot] FAIL: could not create bitmap")
            exit(1)
        }
        view.cacheDisplay(in: bounds, to: representation)
        guard let png = representation.representation(using: .png, properties: [:]) else {
            print("[uishot] FAIL: could not encode bitmap")
            exit(1)
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("[uishot] wrote \(path)")
            exit(0)
        } catch {
            print("[uishot] FAIL: \(error.localizedDescription)")
            exit(1)
        }
    }

    @MainActor
    private static func renderMonitoring(path: String) async -> Never {
        try? await Task.sleep(for: .seconds(1))
        let dark = !CommandLine.arguments.contains("--light-fixture")
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let surface: AnyView
        if CommandLine.arguments.contains("--codex-ui-fixture"), let id = AppModel.shared.selectedWorkspaceChatID {
            surface = AnyView(CodexInteractiveView(chatID: id))
        } else if CommandLine.arguments.contains("--claude-ui-fixture") {
            if CommandLine.arguments.contains("--inspect-ai-settings"), let id = AppModel.shared.selectedWorkspaceChatID {
                surface = AnyView(ChatBackendSettingsView(chatID: id, initialBackend: .claude))
            } else { surface = AnyView(ProjectChatWorkspaceView()) }
        } else if CommandLine.arguments.contains("--workspace-fixture") {
            // NavigationSplitView's AppKit-backed columns do not reliably
            // appear in cacheDisplay. Render the actual new workspace surface
            // directly, not an empty full-window snapshot.
            if CommandLine.arguments.contains("--inspect-context"), let id = AppModel.shared.selectedWorkspaceChatID {
                surface = AnyView(WorkspaceInspectorView(chatID: id))
            } else if CommandLine.arguments.contains("--inspect-boundaries"), let id = AppModel.shared.selectedWorkspaceProjectID {
                surface = AnyView(WorkspaceBoundaryReviewView(projectID: id))
            } else {
                surface = AnyView(ProjectChatWorkspaceView(
                    recent: CommandLine.arguments.contains("--recent-fixture")))
            }
        } else if CommandLine.arguments.contains("--capture-setup-fixture") {
            surface = AnyView(CaptureSetupView(onClose: {}))
        } else if CommandLine.arguments.contains("--activity-panel-fixture") {
            surface = AnyView(ActivityStatusPanel())
        } else if CommandLine.arguments.contains("--operation-detail-fixture"),
                  let run = AppModel.shared.recentActivityRuns.first(where: { $0.state == .succeeded }) {
            surface = AnyView(ActivityRunDetailView(run: run))
        } else { surface = AnyView(MainWindow()) }
        let root = surface.environment(AppModel.shared).preferredColorScheme(dark ? .dark : .light)
            .frame(width: 1080, height: 780)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 780),
            styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: root)
        window.contentView = host
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(for: .seconds(1))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
        do { try png.write(to: URL(fileURLWithPath: path)); print("[uishot] wrote isolated monitoring fixture"); exit(0) }
        catch { print("[uishot] FAIL: could not save fixture"); exit(1) }
    }

    @MainActor
    private static func renderCompanionFixture(path: String, fixture: String) async -> Never {
        // Static, in-memory data only. No bootstrap, devices or providers.
        let model = AppModel.shared
        let dark = !CommandLine.arguments.contains("--light-fixture")
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        model.companionPresentation = .minimal
        if fixture == "chat" {
            model.messages = [
                DisplayMessage(role: .user, text: "What is the key idea in this example lecture?"),
                DisplayMessage(role: .assistant, text: "The gradient points toward the steepest local increase. Gradient descent takes a small step in the opposite direction. The current capture keeps running while we discuss it.")
            ]
        }
        let controller = CompanionPanelController(model: model)
        let state = controller.overlayState
        state.subtitlesVisible = fixture == "subtitles" || fixture == "chat"
        state.chatExpanded = fixture == "chat"
        state.draft = "Can you explain the step size with a small example?"
        let expectedDraft = state.draft
        let expectedSubtitles = state.subtitlesVisible
        let expectedChat = state.chatExpanded
        let expectedCaption = model.capture?.liveCaption
        guard model.capture?.isActive == true else {
            print("[uishot] FAIL: synthetic capture fixture is not active")
            exit(1)
        }

        controller.show()
        try? await Task.sleep(for: .seconds(0.25))
        controller.hide()
        try? await Task.sleep(for: .seconds(0.15))
        guard !controller.isVisible, !state.isVisible,
              state.draft == expectedDraft,
              state.subtitlesVisible == expectedSubtitles,
              state.chatExpanded == expectedChat,
              model.capture?.isActive == true,
              model.capture?.liveCaption == expectedCaption,
              !model.isResponding else {
            print("[uishot] FAIL: hiding companion altered draft, visibility settings or synthetic capture")
            exit(1)
        }

        controller.show()
        try? await Task.sleep(for: .seconds(0.8))
        guard controller.isVisible, state.isVisible,
              state.draft == expectedDraft,
              state.subtitlesVisible == expectedSubtitles,
              state.chatExpanded == expectedChat,
              model.capture?.isActive == true,
              model.capture?.liveCaption == expectedCaption,
              !model.isResponding,
              let host = controller.diagnosticContentView else {
            print("[uishot] FAIL: showing companion altered retained state or synthetic capture")
            exit(1)
        }
        func hasAvatar(_ view: NSView) -> Bool {
            view is TransparentSceneView || view.subviews.contains { hasAvatar($0) }
        }
        host.layoutSubtreeIfNeeded()
        guard !hasAvatar(host) else {
            print("[uishot] FAIL: minimal companion fixture mounted an avatar renderer")
            exit(1)
        }
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            print("[uishot] FAIL: could not create companion fixture bitmap")
            exit(1)
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            print("[uishot] FAIL: could not encode companion fixture bitmap")
            exit(1)
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("[uishot] wrote synthetic companion \(fixture): \(path)")
            print("[uishot] hide/show retained draft, independent toggles and synthetic capture; no avatar renderer")
            exit(0)
        } catch {
            print("[uishot] FAIL: could not save companion fixture")
            exit(1)
        }
    }

    @MainActor
    private static func renderCompanion(path: String) async -> Never {
        // A bootstrap-free check: no inference, voice engines or account access.
        AppModel.shared.companionPresentation = .minimal
        let controller = CompanionPanelController(model: AppModel.shared)
        controller.show()
        try? await Task.sleep(for: .seconds(0.8))
        guard let host = controller.diagnosticContentView else { exit(1) }
        host.layoutSubtreeIfNeeded()
        func avatars(in view: NSView) -> [TransparentSceneView] {
            (view as? TransparentSceneView).map { [$0] } ?? view.subviews.flatMap { avatars(in: $0) }
        }
        guard avatars(in: host).isEmpty,
              controller.diagnosticFrame.size == CompanionPresentation.minimal.panelSize else {
            print("[uishot] FAIL: minimal overlay contains an avatar renderer")
            exit(1)
        }
        // Capture startup separately from lifecycle assertions: cacheDisplay
        // does not reliably flatten layer-backed controls after a Metal view
        // has been removed from this same hosting view.
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
        if CommandLine.arguments.contains("--test-companion-switch") {
            let anchor = controller.diagnosticFrame
            AppModel.shared.companionPresentation = .avatar
            try? await Task.sleep(for: .seconds(1))
            let previousAvatars = avatars(in: host)
            guard !previousAvatars.isEmpty,
                  controller.diagnosticFrame.size == CompanionPresentation.avatar.panelSize else {
                print("[uishot] FAIL: avatar mode did not mount and resize")
                exit(1)
            }
            AppModel.shared.companionPresentation = .minimal
            try? await Task.sleep(for: .seconds(0.5))
            guard avatars(in: host).isEmpty, previousAvatars.allSatisfy({ $0.scene == nil }),
                  controller.diagnosticFrame.size == CompanionPresentation.minimal.panelSize,
                  abs(controller.diagnosticFrame.maxX - anchor.maxX) < 1,
                  abs(controller.diagnosticFrame.minY - anchor.minY) < 1 else {
                print("[uishot] FAIL: switching did not detach avatar or preserve panel anchor")
                exit(1)
            }
            print("[uishot] mode switching passed: renderer detached; panel resized and anchor preserved")
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("[uishot] wrote minimal overlay; no avatar renderer in hierarchy")
            exit(0)
        } catch {
            print("[uishot] FAIL: \(error.localizedDescription)")
            exit(1)
        }
    }

    @MainActor
    private static func renderSetup(path: String) async -> Never {
        let args = CommandLine.arguments
        let page = args.firstIndex(of: "--setup-page").flatMap { index in
            index + 1 < args.count ? SetupPage(rawValue: args[index + 1]) : nil
        } ?? .overview
        // No bootstrap: screenshot QA must not start engines, connect accounts,
        // request permissions, download models, or touch personal profile data.
        let host = NSHostingView(rootView: OnboardingView(initialPage: page).environment(AppModel.shared))
        let width = ProcessInfo.processInfo.environment["AITVARAS_UI_TEST_WIDTH"].flatMap(Double.init) ?? 900
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 680),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(0.8))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            print("[uishot] FAIL: no Setup bitmap")
            exit(1)
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            print("[uishot] FAIL: no Setup PNG")
            exit(1)
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("[uishot] wrote Setup \(page.rawValue)")
            exit(0)
        } catch {
            print("[uishot] FAIL: \(error.localizedDescription)")
            exit(1)
        }
    }
}

/// Lives inside the real Window scene so openWindow uses its actual scene
/// environment. No bootstrap, capture, account or model is started by this test.
struct SingleMainWindowProbe: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Color.clear.frame(width: 1, height: 1).allowsHitTesting(false)
            .task {
                openWindow(id: "main")
                openWindow(id: "main")
            }
    }
}
