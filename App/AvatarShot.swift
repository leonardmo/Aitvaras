import Foundation
import AppKit
import SceneKit
import AitvarasCore

/// Headless render of the avatar scene to a PNG
/// (`Aitvaras --avatarshot /path/out.png`) — lets the avatar be inspected
/// and iterated on without a display.
enum AvatarShot {
    static var requestedPath: String? {
        guard let idx = CommandLine.arguments.firstIndex(of: "--avatarshot"),
              CommandLine.arguments.count > idx + 1 else { return nil }
        return CommandLine.arguments[idx + 1]
    }

    static var liveshotPath: String? {
        guard let idx = CommandLine.arguments.firstIndex(of: "--liveshot"),
              CommandLine.arguments.count > idx + 1 else { return nil }
        return CommandLine.arguments[idx + 1]
    }

    /// On-screen verification: real SCNView in a real window (display
    /// link runs, animation players tick), snapshot at ~1s and ~4s to
    /// `<path>` and `<path>2.png`, then exit. Proves baked clips play.
    @MainActor
    static func runLive(path: String) async -> Never {
        let view = SCNView(frame: NSRect(x: 0, y: 0, width: 440, height: 520))
        let controller = AvatarController()
        controller.attach(to: view)
        // Optional forced state/mouth for previewing speaking poses.
        let envv = ProcessInfo.processInfo.environment
        let previewState: CharacterState = {
            switch envv["AITVARAS_SHOT_STATE"] {
            case "speaking": return .speaking
            case "thinking": return .thinking
            case "idle": return .idle
            default: return .listening
            }
        }()
        let previewMouth = Float(envv["AITVARAS_SHOT_MOUTH"] ?? "0") ?? 0
        controller.apply(state: previewState, mouth: previewMouth)

        let window = NSWindow(contentRect: view.frame,
                              styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.level = .floating
        window.contentView = view
        window.orderFrontRegardless()

        try? await Task.sleep(for: .seconds(2.5))   // GLB load + settle
        controller.apply(state: previewState, mouth: previewMouth)   // re-apply after load
        func save(_ image: NSImage, _ p: String) {
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: URL(fileURLWithPath: p))
        }
        let bone = controller.scene?.rootNode.childNode(withName: "Bip001_Head_011", recursively: true)
        func boneReport(_ tag: String) {
            guard let bone else { print("[liveshot] bone NOT FOUND"); return }
            let p = bone.presentation.worldPosition
            print("[liveshot] \(tag) head bone at (\(p.x), \(p.y), \(p.z))")
        }
        boneReport("t0")
        save(view.snapshot(), path)
        try? await Task.sleep(for: .seconds(3))
        boneReport("t3")
        save(view.snapshot(), path.replacingOccurrences(of: ".png", with: "2.png"))
        print("[liveshot] wrote \(path) (+2)")
        exit(0)
    }

    @MainActor
    static func run(path: String) async -> Never {
        let view = SCNView(frame: NSRect(x: 0, y: 0, width: 440, height: 520))
        let controller = AvatarController()
        controller.attach(to: view)
        controller.apply(state: .listening, mouth: 0)

        // Give async GLB loading / scene setup a moment.
        try? await Task.sleep(for: .seconds(2))

        guard let scene = controller.scene,
              let device = MTLCreateSystemDefaultDevice() else {
            print("[avatarshot] FAIL: no scene or Metal device")
            exit(1)
        }
        // Diagnostics: animation players in the scene.
        scene.rootNode.enumerateHierarchy { node, _ in
            for key in node.animationKeys {
                guard let player = node.animationPlayer(forKey: key) else { continue }
                let anim = player.animation
                print("[avatarshot] player '\(key)' on \(node.name ?? "?"): " +
                      "duration=\(anim.duration) paused=\(player.paused) " +
                      "sceneTimeBase=\(anim.usesSceneTimeBase) speed=\(player.speed)")
            }
        }
        scene.background.contents = NSColor(calibratedWhite: 0.1, alpha: 1)
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = scene.rootNode.childNodes(passingTest: { node, _ in
            node.camera != nil
        }).first
        renderer.autoenablesDefaultLighting = false

        // Animation players start their clock on the first render — do a
        // throwaway render now, then sample AITVARAS_SHOT_TIME seconds in.
        let shotTime = ProcessInfo.processInfo.environment["AITVARAS_SHOT_TIME"]
            .flatMap(Double.init) ?? 0
        let size = CGSize(width: 440, height: 520)
        let start = CACurrentMediaTime()
        _ = renderer.snapshot(atTime: start, with: size, antialiasingMode: .none)
        let image = renderer.snapshot(atTime: start + shotTime,
                                      with: size, antialiasingMode: .multisampling4X)

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("[avatarshot] FAIL: could not encode")
            exit(1)
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("[avatarshot] wrote \(path), pointOfView=\(renderer.pointOfView?.position ?? SCNVector3Zero)")
            exit(0)
        } catch {
            print("[avatarshot] FAIL: \(error)")
            exit(1)
        }
    }
}
