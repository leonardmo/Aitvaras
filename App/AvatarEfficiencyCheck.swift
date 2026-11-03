import AppKit
import SceneKit
import Foundation
import AitvarasCore
import CoreGraphics

/// Counts actual SceneKit frames rather than inferring GPU idleness solely
/// from configuration flags. Only used by the explicit diagnostic mode.
private final class AvatarFrameCounter: NSObject, SCNSceneRendererDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    func renderer(_ renderer: any SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
        lock.lock(); frames += 1; lock.unlock()
    }
    func count() -> Int {
        lock.lock(); defer { lock.unlock() }
        return frames
    }
}

/// Optional offscreen diagnostic seam. It never wakes a physical display;
/// only this test window reports a visible region while the display sleeps.
private final class AvatarDiagnosticWindow: NSWindow {
    var virtualDisplay = false
    override var occlusionState: NSWindow.OcclusionState {
        virtualDisplay ? [.visible] : super.occlusionState
    }
}

enum AvatarEfficiencyCheck {
    static var requestedPath: String? {
        guard let index = CommandLine.arguments.firstIndex(of: "--avatar-efficiency-check"),
              CommandLine.arguments.count > index + 1 else { return nil }
        return CommandLine.arguments[index + 1]
    }

    @MainActor
    static func run(path: String) async -> Never {
        let view = TransparentSceneView(frame: NSRect(x: 0, y: 0, width: 272, height: 282))
        view.backgroundColor = .clear
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling2X
        view.preferredFramesPerSecond = 30
        let counter = AvatarFrameCounter()
        view.delegate = counter
        let controller = AvatarController()
        controller.attach(to: view)
        let virtualDisplay = ProcessInfo.processInfo.environment["AITVARAS_DIAGNOSTIC_VIRTUAL_DISPLAY"] == "1"
        let physicalDisplaySleeping = CGDisplayIsAsleep(CGMainDisplayID()) != 0
        let window = AvatarDiagnosticWindow(contentRect: view.frame, styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
        window.virtualDisplay = virtualDisplay
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.contentView = view
        window.orderFrontRegardless()
        if virtualDisplay {
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
            controller.refreshVisibility()
        }
        var results: [[String: Any]] = []
        var failures: [String] = []
        var skipped: [String] = []
        func check(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }
        func delay(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
        func sample(_ name: String, seconds: Double = 0.65) async -> Int {
            let start = counter.count()
            let startedAt = ProcessInfo.processInfo.systemUptime
            await delay(seconds)
            let frames = counter.count() - start
            let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
            let d = controller.diagnosticRendering()
            results.append(["phase": name, "frames": frames, "seconds": elapsed,
                            "requestedSeconds": seconds, "framesPerSecond": Double(frames) / max(elapsed, 0.001),
                            "mode": String(describing: d.decision.mode), "visible": d.visibility.canRender,
                            "attached": d.visibility.isAttached, "windowVisible": d.visibility.isWindowVisible,
                            "occluded": d.visibility.isWindowOccluded, "displaySleeping": d.visibility.isDisplaySleeping,
                            "systemSleeping": d.visibility.isSystemSleeping, "appHidden": d.visibility.isAppHidden,
                            "playing": d.isPlaying, "continuous": d.rendersContinuously,
                            "scenePaused": d.isScenePaused, "visualTasks": controller.diagnosticVisualTaskCount])
            return frames
        }
        func suspended(_ phase: String) async {
            await delay(0.25)
            let d = controller.diagnosticRendering()
            check(d.decision.mode == .suspended, phase + ": not suspended")
            check(!d.isPlaying && !d.rendersContinuously && d.isScenePaused, phase + ": render flags still active")
            check(controller.diagnosticVisualTaskCount == 0, phase + ": visual task still scheduled")
            let frames = await sample(phase)
            check(frames == 0, phase + ": rendered while suspended")
        }
        for _ in 0..<100 {
            if controller.scene?.rootNode.childNode(withName: "RuntimeDragon", recursively: true) != nil { break }
            await delay(0.05)
        }
        check(controller.scene?.rootNode.childNode(withName: "RuntimeDragon", recursively: true) != nil,
              "Runtime dragon did not load")
        await delay(0.85)
        let idle = await sample("visible-idle")
        check(idle <= 1, "Idle renderer kept producing frames")
        check(view.scene == nil, "Idle renderer still has a live scene attached")
        controller.apply(state: .speaking, mouth: 0.75)
        await delay(0.15)
        let speaking = await sample("visible-speaking")
        if physicalDisplaySleeping {
            skipped.append("Active display-link cadence: physical display asleep; no display was awakened.")
        } else {
            check(speaking >= 3 && speaking <= 24, "Active frame cadence outside expected cap")
        }
        let image = view.snapshot()
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("png"))
        }
        window.orderOut(nil)
        if virtualDisplay { controller.refreshVisibility() }
        await suspended("window-hidden")
        for _ in 0..<10 { controller.apply(state: .thinking, mouth: 1) }
        await suspended("hidden-model-updates")
        window.orderFrontRegardless()
        if virtualDisplay { controller.refreshVisibility() }
        await delay(0.85)
        check(controller.diagnosticRendering().visibility.canRender, "Window did not resume")
        controller.apply(state: .idle, mouth: 0)
        await delay(0.85)
        let resumedIdle = await sample("resumed-idle")
        check(resumedIdle <= 1 && view.scene == nil, "Resumed idle did not return to a still frame")
        if !virtualDisplay && !physicalDisplaySleeping {
            let cover = NSWindow(contentRect: window.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            cover.isReleasedWhenClosed = false
            cover.isOpaque = true
            cover.backgroundColor = .white
            cover.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
            cover.orderFrontRegardless()
            await suspended("window-occluded")
            cover.orderOut(nil)
            await delay(0.85)
            check(controller.diagnosticRendering().visibility.canRender, "Unoccluded window did not resume")
            window.miniaturize(nil)
            await suspended("window-minimized")
            window.deminiaturize(nil)
            window.orderFrontRegardless()
            await delay(0.85)
            check(controller.diagnosticRendering().visibility.canRender, "Deminimized window did not resume")
            NSApp.hide(nil)
            await suspended("application-hidden")
            NSApp.unhideWithoutActivation()
            window.orderFrontRegardless()
            await delay(0.85)
            check(controller.diagnosticRendering().visibility.canRender, "Unhidden app did not resume")
        } else {
            skipped.append("Physical occlusion, minimization and application-hide checks require an awake display without virtual occlusion.")
        }
        view.isHidden = true
        await suspended("view-hidden")
        view.isHidden = false
        await delay(0.85)
        // Exercise notification paths without putting the user's Mac to sleep.
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        await suspended("display-sleep-notification")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        await delay(0.85)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        await suspended("system-sleep-notification")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        await delay(0.85)
        controller.detach()
        await suspended("detached")
        window.orderOut(nil)
        let report: [String: Any] = ["passed": failures.isEmpty, "phases": results, "failures": failures, "skipped": skipped,
                                     "virtualDisplay": virtualDisplay,
                                     "scope": "Real SCNView frame counts; sleep notifications simulated. Optional virtual display overrides test-window occlusion only. Not a whole-app power measurement."]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        print("AVATAR_EFFICIENCY_CHECK " + (failures.isEmpty ? "PASS" : failures.joined(separator: "; ")))
        exit(failures.isEmpty ? 0 : 1)
    }
}
