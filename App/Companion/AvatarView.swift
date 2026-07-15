import SwiftUI
import SceneKit
import GLTFKit2
import AitvarasCore

/// SceneKit otherwise advertises an opaque backing layer even when its
/// background color is clear, which prevents the desktop from showing
/// through translucent room geometry.
private final class TransparentSceneView: SCNView {
    override var isOpaque: Bool { false }
}

/// Renders Aitvaras (D4): the user's Ready Player Me GLB when installed,
/// otherwise a placeholder mannequin. Blink + jaw lip-sync via ARKit
/// blendshapes; states drive subtle motion.
struct AvatarView: NSViewRepresentable {
    @Environment(AppModel.self) private var model

    func makeCoordinator() -> AvatarController {
        AvatarController()
    }

    func makeNSView(context: Context) -> SCNView {
        let view = TransparentSceneView()
        view.wantsLayer = true
        view.layer?.isOpaque = false
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.autoenablesDefaultLighting = false
        view.rendersContinuously = true
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        context.coordinator.apply(state: model.characterState, mouth: model.mouthLevel)
    }
}

/// Owns the SceneKit scene + animation state machine.
@MainActor
final class AvatarController {
    private weak var view: SCNView?
    private(set) var scene: SCNScene?
    private var morphNodes: [SCNNode] = []          // nodes with blendshape morphers
    private var headNode: SCNNode?
    private var rootContainer = SCNNode()
    private var blinkTask: Task<Void, Never>?
    private var timeOfDayTask: Task<Void, Never>?
    private var windowMaterial: SCNMaterial?
    private var windowLight: SCNNode?
    private var currentState: CharacterState = .idle
    private var smoothedMouth: Float = 0

    // Procedural creature (cute cartoon dragon) — driven by the same
    // state machine as the human avatar, with hand-built expressive parts.
    private var usingCreature = false
    private var creatureEyes: [SCNNode] = []          // whole eye groups (blink by Y-scale)
    private var creaturePupils: [SCNNode] = []        // dark iris — faint mood glow
    private var creatureJaw: SCNNode?                 // lower jaw — opens with her voice
    private var creatureSmile: SCNNode?               // smile line — shown when mouth is closed
    private var creatureWings: [SCNNode] = []
    private var creatureCheeks: [SCNNode] = []        // blush — brightens with mood
    private var creatureEyeBaseScale = SCNVector3(1, 1, 1)   // per-state; blink restores to it
    private var creatureFlame: SCNNode?               // tail flame — flares with her voice

    func attach(to view: SCNView) {
        self.view = view
        let scene = SCNScene()
        scene.background.contents = NSColor.clear
        self.scene = scene
        view.scene = scene
        // Baked idle clips must keep ticking even when SceneKit thinks
        // the scene is quiescent.
        view.isPlaying = true

        setupLights(scene)
        setupRoom(scene)
        loadAvatar()
        startBlinking()

        NotificationCenter.default.addObserver(
            forName: .aitvarasAvatarChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.loadAvatar() }
        }
        NotificationCenter.default.addObserver(
            forName: .aitvarasMailArrived, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.playMailDrop() }
        }
    }

    // MARK: Virtual room — a quiet study diorama behind/around her.

    private func setupRoom(_ scene: SCNScene) {
        let room = SCNNode()
        room.name = "Room"

        func matte(_ color: NSColor, constant: Bool = false) -> SCNMaterial {
            let m = SCNMaterial()
            m.diffuse.contents = color
            if constant { m.lightingModel = .constant } else { m.roughness.contents = 0.85 }
            return m
        }

        // Back wall — a warm gradient panel that stays visible at every
        // hour (the window sets the mood; interior lamps carry the light).
        let wall = SCNNode(geometry: SCNPlane(width: 3.4, height: 2.8))
        let wallMat = SCNMaterial()
        wallMat.diffuse.contents = Self.verticalGradientImage(
            top: NSColor(calibratedRed: 0.50, green: 0.46, blue: 0.64, alpha: 1),
            bottom: NSColor(calibratedRed: 0.32, green: 0.29, blue: 0.44, alpha: 1))
        wallMat.lightingModel = .constant
        wallMat.transparency = 0.34
        wallMat.blendMode = .alpha
        wall.geometry?.materials = [wallMat]
        wall.position = SCNVector3(0, 1.35, -0.72)
        room.addChildNode(wall)

        // Floor plane meeting the wall, warm wood tone.
        let floor = SCNNode(geometry: SCNPlane(width: 3.4, height: 1.4))
        floor.geometry?.materials = [matte(NSColor(calibratedRed: 0.34, green: 0.29, blue: 0.25, alpha: 1))]
        floor.eulerAngles.x = -.pi / 2
        floor.position = SCNVector3(0, 0.0, -0.1)
        floor.opacity = 0.68
        room.addChildNode(floor)

        // Warm interior fill so the scene is NEVER black regardless of
        // time of day.
        let lamp = SCNNode()
        lamp.light = SCNLight()
        lamp.light!.type = .omni
        lamp.light!.intensity = 42
        lamp.light!.categoryBitMask = 1
        lamp.light!.color = NSColor(calibratedRed: 1.0, green: 0.9, blue: 0.75, alpha: 1)
        lamp.position = SCNVector3(-0.5, 1.9, 0.2)
        room.addChildNode(lamp)

        // String of tiny warm fairy lights along the top of the wall —
        // cozy, always on, cheap.
        for i in 0..<9 {
            let bulbMat = SCNMaterial()
            bulbMat.lightingModel = .constant
            bulbMat.diffuse.contents = NSColor.black
            bulbMat.emission.contents = NSColor(calibratedRed: 1.0, green: 0.82, blue: 0.5, alpha: 1)
            bulbMat.emission.intensity = 1.4
            let bulb = SCNNode(geometry: SCNSphere(radius: 0.008))
            bulb.geometry?.materials = [bulbMat]
            let x = -0.9 + Double(i) * 0.225
            let sag = 0.035 * sin(Double(i) / 8 * .pi)
            bulb.position = SCNVector3(x, 2.06 - sag, -0.7)
            room.addChildNode(bulb)
        }

        // A little plant on the left, at shelf depth — organic warmth.
        let pot = SCNNode(geometry: SCNCylinder(radius: 0.035, height: 0.05))
        pot.geometry?.materials = [matte(NSColor(calibratedRed: 0.72, green: 0.45, blue: 0.35, alpha: 1))]
        pot.position = SCNVector3(-0.46, 1.565, -0.56)
        room.addChildNode(pot)
        for (dx, dz, s) in [(0.0, 0.0, 1.0), (0.02, 0.015, 0.75), (-0.022, -0.01, 0.8)] {
            let leaf = SCNNode(geometry: SCNSphere(radius: 0.028))
            leaf.geometry?.materials = [matte(NSColor(calibratedRed: 0.35, green: 0.58, blue: 0.38, alpha: 1))]
            leaf.scale = SCNVector3(0.8 * s, 1.25 * s, 0.8 * s)
            leaf.position = SCNVector3(-0.46 + dx, 1.63 + 0.02 * s, -0.56 + dz)
            room.addChildNode(leaf)
        }

        // Window peeking in at the right edge — a living clock: its light
        // follows the real time of day (updated every few minutes).
        let window = SCNNode(geometry: SCNPlane(width: 0.36, height: 0.62))
        let windowMaterial = SCNMaterial()
        windowMaterial.diffuse.contents = NSColor.black
        windowMaterial.lightingModel = .constant
        window.geometry?.materials = [windowMaterial]
        window.position = SCNVector3(0.46, 1.56, -0.66)
        window.opacity = 0.86
        room.addChildNode(window)
        // Frame bars so it reads as a window, not a glowing slab.
        for barY in [1.56] {
            let bar = SCNNode(geometry: SCNBox(width: 0.37, height: 0.015, length: 0.01, chamferRadius: 0))
            bar.geometry?.materials = [matte(NSColor(calibratedRed: 0.2, green: 0.18, blue: 0.17, alpha: 1))]
            bar.position = SCNVector3(0.46, CGFloat(barY), -0.655)
            room.addChildNode(bar)
        }
        let vBar = SCNNode(geometry: SCNBox(width: 0.015, height: 0.63, length: 0.01, chamferRadius: 0))
        vBar.geometry?.materials = [matte(NSColor(calibratedRed: 0.2, green: 0.18, blue: 0.17, alpha: 1))]
        vBar.position = SCNVector3(0.46, 1.56, -0.655)
        room.addChildNode(vBar)

        let windowLight = SCNNode()
        windowLight.light = SCNLight()
        windowLight.light!.type = .omni
        windowLight.light!.intensity = 55
        windowLight.light!.categoryBitMask = 1
        windowLight.position = SCNVector3(0.75, 1.6, -0.5)
        room.addChildNode(windowLight)
        self.windowMaterial = windowMaterial
        self.windowLight = windowLight
        updateTimeOfDay(animated: false)

        // Bookshelf peeking in at the left edge — where mail envelopes land.
        let shelf = SCNNode(geometry: SCNBox(width: 0.4, height: 0.02, length: 0.13, chamferRadius: 0.004))
        shelf.geometry?.materials = [matte(NSColor(calibratedRed: 0.34, green: 0.27, blue: 0.20, alpha: 1))]
        shelf.position = SCNVector3(-0.48, 1.52, -0.58)
        shelf.name = "Shelf"
        room.addChildNode(shelf)

        let bookColors = [NSColor(calibratedRed: 0.62, green: 0.34, blue: 0.30, alpha: 1),
                          NSColor(calibratedRed: 0.28, green: 0.44, blue: 0.49, alpha: 1),
                          NSColor(calibratedRed: 0.80, green: 0.69, blue: 0.47, alpha: 1),
                          NSColor(calibratedRed: 0.36, green: 0.47, blue: 0.42, alpha: 1)]
        for (index, color) in bookColors.enumerated() {
            let book = SCNNode(geometry: SCNBox(width: 0.03, height: 0.14, length: 0.10, chamferRadius: 0.002))
            book.geometry?.materials = [matte(color)]
            book.position = SCNVector3(-0.60 + CGFloat(index) * 0.036, 1.60, -0.58)
            book.eulerAngles.z = CGFloat([0, 0, 0.16, 0][index])   // one leaning
            room.addChildNode(book)
        }

        scene.rootNode.addChildNode(room)

        timeOfDayTask?.cancel()
        timeOfDayTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                await self?.updateTimeOfDay(animated: true)
            }
        }
    }

    /// Sky + light through the window by real local time.
    private func updateTimeOfDay(animated: Bool) {
        let hour = Calendar.current.component(.hour, from: .now)
        let minute = Calendar.current.component(.minute, from: .now)
        let time = Double(hour) + Double(minute) / 60

        let sky: NSColor
        let lightColor: NSColor
        let lightIntensity: CGFloat
        switch time {
        case 5.5..<8:      // dawn
            sky = NSColor(calibratedRed: 0.95, green: 0.62, blue: 0.48, alpha: 1)
            lightColor = NSColor(calibratedRed: 1.0, green: 0.75, blue: 0.6, alpha: 1)
            lightIntensity = 70
        case 8..<17:       // day
            sky = NSColor(calibratedRed: 0.62, green: 0.78, blue: 0.92, alpha: 1)
            lightColor = NSColor(calibratedRed: 0.9, green: 0.95, blue: 1.0, alpha: 1)
            lightIntensity = 60
        case 17..<21:      // golden hour / dusk
            sky = NSColor(calibratedRed: 0.92, green: 0.55, blue: 0.30, alpha: 1)
            lightColor = NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.45, alpha: 1)
            lightIntensity = 85
        default:           // night
            sky = NSColor(calibratedRed: 0.12, green: 0.16, blue: 0.30, alpha: 1)
            lightColor = NSColor(calibratedRed: 0.55, green: 0.65, blue: 0.95, alpha: 1)
            lightIntensity = 28
        }

        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated ? 3 : 0
        windowMaterial?.emission.contents = sky
        windowMaterial?.emission.intensity = 0.5
        windowLight?.light?.color = lightColor
        windowLight?.light?.intensity = lightIntensity
        SCNTransaction.commit()
    }

    /// New-mail moment: an envelope drops onto the desk and fades out.
    func playMailDrop() {
        guard let scene else { return }
        let envelope = SCNNode(geometry: SCNBox(width: 0.09, height: 0.003, length: 0.062, chamferRadius: 0.001))
        let material = SCNMaterial()
        material.diffuse.contents = NSColor(calibratedWhite: 0.92, alpha: 1)
        envelope.geometry?.materials = [material]
        let accent = SCNNode(geometry: SCNBox(width: 0.088, height: 0.0035, length: 0.01, chamferRadius: 0.001))
        let accentMaterial = SCNMaterial()
        accentMaterial.diffuse.contents = NSColor(calibratedRed: 0.4, green: 0.85, blue: 0.78, alpha: 1)
        accent.geometry?.materials = [accentMaterial]
        accent.position.z = -0.02
        envelope.addChildNode(accent)

        // Drops onto the bookshelf, left of her head.
        envelope.position = SCNVector3(-0.44, 1.95, -0.58)
        envelope.eulerAngles = SCNVector3(0.3, 0.4, 0.2)
        envelope.opacity = 0
        scene.rootNode.addChildNode(envelope)

        let appear = SCNAction.fadeIn(duration: 0.2)
        let fall = SCNAction.group([
            .move(to: SCNVector3(-0.44, 1.55, -0.58), duration: 0.8),
            .rotateTo(x: 0, y: 0.4, z: 0, duration: 0.8)
        ])
        fall.timingMode = .easeIn
        let settle = SCNAction.sequence([
            .moveBy(x: 0, y: 0.018, z: 0, duration: 0.1),
            .moveBy(x: 0, y: -0.018, z: 0, duration: 0.12)
        ])
        let rest = SCNAction.wait(duration: 14)
        let vanish = SCNAction.fadeOut(duration: 1.2)
        envelope.runAction(.sequence([appear, fall, settle, rest, vanish, .removeFromParentNode()]))
    }

    /// Holographic rim treatment: a fresnel glow in her accent color on
    /// every avatar material — reads "virtual being", not costume.
    private func applyHolographicRim(to root: SCNNode) {
        let fragment = """
        #pragma body
        float3 viewDirection = normalize(_surface.view);
        float rim = pow(1.0 - clamp(dot(_surface.normal, viewDirection), 0.0, 1.0), 2.6);
        float3 shaded = _output.color.rgb * 0.75;
        _output.color.rgb = (shaded / (float3(1.0) + shaded)) * 0.60;
        float luminance = dot(_output.color.rgb, float3(0.2126, 0.7152, 0.0722));
        _output.color.rgb = mix(float3(luminance), _output.color.rgb, 1.28);
        _output.color.rgb += float3(0.25, 0.85, 0.78) * rim * 0.06;
        """
        let skinFragment = """
        #pragma body
        float3 viewDirection = normalize(_surface.view);
        float rim = pow(1.0 - clamp(dot(_surface.normal, viewDirection), 0.0, 1.0), 2.6);
        float3 shaded = _output.color.rgb * 0.75;
        _output.color.rgb = (shaded / (float3(1.0) + shaded)) * 0.60;
        float luminance = dot(_output.color.rgb, float3(0.2126, 0.7152, 0.0722));
        _output.color.rgb = mix(float3(luminance), _output.color.rgb, 1.28)
            * float3(0.78, 0.70, 0.66);
        _output.color.rgb += float3(0.25, 0.85, 0.78) * rim * 0.035;
        """
        root.enumerateHierarchy { node, _ in
            for material in node.geometry?.materials ?? [] {
                let isSkin = material.name?.lowercased().contains("skin") == true
                    || node.name?.lowercased().contains("head") == true
                material.shaderModifiers = [.fragment: isSkin ? skinFragment : fragment]
            }
        }
    }

    /// Simple vertical gradient texture (for walls / lighting environment).
    static func verticalGradientImage(top: NSColor, bottom: NSColor) -> NSImage {
        let size = NSSize(width: 64, height: 256)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGradient(starting: bottom, ending: top)?
            .draw(in: NSRect(origin: .zero, size: size), angle: 90)
        image.unlockFocus()
        return image
    }

    /// Soft radial shadow texture (dark center fading to clear).
    static func radialShadowImage() -> NSImage {
        let size = NSSize(width: 128, height: 128)
        let image = NSImage(size: size)
        image.lockFocus()
        let gradient = NSGradient(colors: [
            NSColor.black.withAlphaComponent(0.4),
            NSColor.black.withAlphaComponent(0.0)
        ])
        gradient?.draw(in: NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)),
                       relativeCenterPosition: .zero)
        image.unlockFocus()
        return image
    }

    /// Soft colored radial glow for the dragon's mood aura.
    static func radialGlowImage(_ color: NSColor) -> NSImage {
        let size = NSSize(width: 128, height: 128)
        let image = NSImage(size: size)
        image.lockFocus()
        let gradient = NSGradient(colors: [
            color.withAlphaComponent(0.85),
            color.withAlphaComponent(0.0)
        ])
        gradient?.draw(in: NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)),
                       relativeCenterPosition: .zero)
        image.unlockFocus()
        return image
    }

    private func setupLights(_ scene: SCNScene) {
        // Environment reflections make the PBR shells look alive.
        scene.lightingEnvironment.contents = Self.verticalGradientImage(
            top: NSColor(calibratedRed: 0.7, green: 0.75, blue: 0.85, alpha: 1),
            bottom: NSColor(calibratedRed: 0.25, green: 0.22, blue: 0.28, alpha: 1))
        scene.lightingEnvironment.intensity = 0.09

        let key = SCNNode()
        key.light = SCNLight()
        // A close omni fill gives the face a broad, soft falloff instead
        // of the hard split produced by the old directional key.
        key.light!.type = .omni
        key.light!.intensity = 58
        key.light!.categoryBitMask = 1
        key.light!.color = NSColor(calibratedRed: 1.0, green: 0.93, blue: 0.86, alpha: 1)
        key.position = SCNVector3(-0.75, 1.75, 1.15)
        scene.rootNode.addChildNode(key)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light!.type = .ambient
        ambient.light!.intensity = 82
        ambient.light!.categoryBitMask = 1
        scene.rootNode.addChildNode(ambient)

        let rim = SCNNode()
        rim.light = SCNLight()
        rim.light!.type = .directional
        rim.light!.intensity = 30
        rim.light!.categoryBitMask = 1
        rim.light!.color = NSColor(calibratedRed: 0.4, green: 0.9, blue: 0.82, alpha: 1)
        rim.eulerAngles = SCNVector3(0.3, .pi - 0.4, 0)
        scene.rootNode.addChildNode(rim)
    }

    // MARK: Avatar loading

    private func loadAvatar() {
        guard let scene else { return }
        rootContainer.removeFromParentNode()
        rootContainer = SCNNode()
        morphNodes = []
        headNode = nil
        creatureEyes = []
        creaturePupils = []
        creatureJaw = nil
        creatureSmile = nil
        creatureWings = []
        creatureCheeks = []
        creatureEyeBaseScale = SCNVector3(1, 1, 1)
        creatureFlame = nil
        dragonAura = nil
        creatureHead = nil
        creatureBaseHeadEuler = SCNVector3Zero
        usingCreature = false
        scene.rootNode.addChildNode(rootContainer)

        if AvatarLocator.style == .creature {
            installCreature()
            return
        }

        if let avatarURL = AvatarLocator.effectiveAvatarURL {
            // GLTFKit2 invokes the handler on its own queue — must not
            // inherit this class's @MainActor isolation (runtime trap).
            GLTFAsset.load(with: avatarURL, options: [:]) { @Sendable [weak self] _, status, asset, error, _ in
                nonisolated(unsafe) let loadedAsset = asset
                Task { @MainActor [weak self] in
                    if status == .complete, let loadedAsset {
                        self?.installGLTF(loadedAsset)
                    } else {
                        self?.installPlaceholder()
                        _ = error
                    }
                }
            }
        } else {
            installPlaceholder()
        }
    }

    // MARK: Procedural creature — a cute cartoon dragon matching the
    // user's storybook reference: big highlighted eyes, a smiling mouth
    // that opens when she speaks, seafoam-teal body with a warm orange
    // belly, little wings, horns, a finned crest and a curled tail.
    // Fully hand-built so the face is expressive and the mouth moves.

    private var dragonAura: SCNNode?
    private var creatureHead: SCNNode?           // head group — nods/tilts with state + voice
    private var creatureBaseHeadEuler = SCNVector3Zero

    // Palette after the Aitvaras reference: charcoal-navy body, tan
    // belly plates, fiery red crest, gold horns/claws, ember accents.
    private static let cTeal     = NSColor(calibratedRed: 0.24, green: 0.26, blue: 0.36, alpha: 1)   // body: dark navy
    private static let cTealDeep = NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.25, alpha: 1)   // shadow navy
    private static let cBelly    = NSColor(calibratedRed: 0.83, green: 0.64, blue: 0.40, alpha: 1)   // tan plastron
    private static let cWing     = NSColor(calibratedRed: 0.92, green: 0.45, blue: 0.18, alpha: 1)   // ember orange
    private static let cHorn     = NSColor(calibratedRed: 0.95, green: 0.80, blue: 0.38, alpha: 1)   // gold
    private static let cCrest    = NSColor(calibratedRed: 0.80, green: 0.16, blue: 0.12, alpha: 1)   // fiery red
    private static let cMouth    = NSColor(calibratedRed: 0.20, green: 0.08, blue: 0.12, alpha: 1)
    private static let cTongue   = NSColor(calibratedRed: 0.96, green: 0.50, blue: 0.45, alpha: 1)
    private static let cIris     = NSColor(calibratedRed: 0.72, green: 0.44, blue: 0.14, alpha: 1)   // amber
    private static let cCheek    = NSColor(calibratedRed: 0.95, green: 0.52, blue: 0.30, alpha: 1)

    private func skinMat(_ color: NSColor, shiny: Bool = false) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = color
        m.lightingModel = shiny ? .blinn : .lambert
        if shiny { m.specular.contents = NSColor(calibratedWhite: 1, alpha: 1); m.shininess = 0.45 }
        m.locksAmbientWithDiffuse = true
        return m
    }
    /// Smooth sphere primitive on the creature light category.
    private func ball(_ r: CGFloat, _ color: NSColor, shiny: Bool = false) -> SCNNode {
        let s = SCNSphere(radius: r); s.segmentCount = 40
        let n = SCNNode(geometry: s)
        n.geometry!.firstMaterial = skinMat(color, shiny: shiny)
        n.categoryBitMask = 2
        return n
    }
    /// Constant-shaded emissive bit (eye highlights).
    private func lit(_ r: CGFloat, _ color: NSColor) -> SCNNode {
        let n = SCNNode(geometry: SCNSphere(radius: r))
        let m = SCNMaterial(); m.diffuse.contents = color
        m.emission.contents = color; m.lightingModel = .constant
        n.geometry!.firstMaterial = m
        n.categoryBitMask = 2
        return n
    }
    private func cone(_ bottom: CGFloat, _ height: CGFloat, _ color: NSColor) -> SCNNode {
        let n = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: bottom, height: height))
        n.geometry!.firstMaterial = skinMat(color)
        n.categoryBitMask = 2
        return n
    }
    /// A rounded limb segment — a capsule aligned between two points, so
    /// arms and legs bend at real joints instead of being lone blobs.
    private func limb(_ a: SCNVector3, _ b: SCNVector3, _ radius: CGFloat, _ color: NSColor) -> SCNNode {
        let dx = b.x - a.x, dy = b.y - a.y, dz = b.z - a.z
        let len = max(sqrt(dx * dx + dy * dy + dz * dz), 0.001)
        let n = SCNNode(geometry: SCNCapsule(capRadius: radius, height: len))
        n.geometry!.firstMaterial = skinMat(color)
        n.categoryBitMask = 2
        n.position = SCNVector3((a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2)
        let dir = simd_normalize(SIMD3<Float>(Float(dx), Float(dy), Float(dz)))
        n.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: dir)
        return n
    }

    private func installCreature() {
        usingCreature = true
        buildCartoonDragon()
    }

    private func buildCartoonDragon() {
        let env = ProcessInfo.processInfo.environment
        let sizeK = env["AITVARAS_SIZE"].flatMap(Double.init).map { CGFloat($0) } ?? 1.0
        let d = SCNNode()                                 // whole dragon, feet at local y = 0

        // TORSO — sculpted from three forms so she reads as a body, not
        // one ball: a rounder tummy/hips, a narrower chest above it, and a
        // soft neck bridging up to the head.
        let hips = ball(0.15, Self.cTeal)
        hips.scale = SCNVector3(1.06, 0.92, 0.96)
        hips.position = SCNVector3(0, 0.15, 0)
        d.addChildNode(hips)
        let chest = ball(0.122, Self.cTeal)
        chest.scale = SCNVector3(1.02, 1.0, 0.9)
        chest.position = SCNVector3(0, 0.265, 0.012)
        d.addChildNode(chest)
        let neck = ball(0.075, Self.cTeal)
        neck.scale = SCNVector3(0.92, 0.95, 0.88)
        neck.position = SCNVector3(0, 0.325, 0.02)
        d.addChildNode(neck)
        // Collar dimple where the chest meets the neck.
        let collar = ball(0.055, Self.cTealDeep)
        collar.scale = SCNVector3(1.3, 0.5, 0.5)
        collar.position = SCNVector3(0, 0.315, 0.10)
        collar.opacity = 0.35
        d.addChildNode(collar)

        // BELLY — a tall warm-orange plastron up the front, with soft
        // segment plates like the reference.
        let belly = ball(0.108, Self.cBelly)
        belly.scale = SCNVector3(0.9, 1.7, 0.6)
        belly.position = SCNVector3(0, 0.175, 0.078)
        d.addChildNode(belly)
        let seamColor = NSColor(calibratedRed: 0.55, green: 0.38, blue: 0.22, alpha: 1)
        for i in 0..<3 {
            let y = 0.17 + CGFloat(i) * 0.05
            let w = 0.088 - abs(CGFloat(i) - 1) * 0.012      // widest in the middle
            let seam = SCNNode(geometry: SCNBox(width: w, height: 0.005, length: 0.006, chamferRadius: 0.0025))
            let m = SCNMaterial()
            m.diffuse.contents = seamColor
            m.lightingModel = .constant
            m.readsFromDepthBuffer = false                   // clean decal seam
            m.writesToDepthBuffer = false
            seam.geometry!.firstMaterial = m
            seam.position = SCNVector3(0, y, 0.142)
            seam.eulerAngles = SCNVector3(0.18, 0, 0)
            seam.renderingOrder = 15
            seam.categoryBitMask = 2
            d.addChildNode(seam)
        }

        // TAIL — one smooth curl sweeping around her right side, tipped
        // with a soft fin.
        let tailCurve: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (0.03, 0.075, -0.11, 0.05), (0.12, 0.055, -0.10, 0.045),
            (0.175, 0.05, -0.03, 0.038), (0.185, 0.05, 0.05, 0.031),
            (0.155, 0.055, 0.10, 0.024), (0.11, 0.065, 0.12, 0.017)]
        for seg in tailCurve {
            let b = ball(seg.3, Self.cTeal)
            b.position = SCNVector3(seg.0, seg.1, seg.2)
            d.addChildNode(b)
        }
        if let tip = tailCurve.last {
            // The Aitvaras signature: a little flame burning on the tail
            // tip — emissive gold core in an orange shell, flickering
            // gently, flaring with her voice.
            let flame = SCNNode()
            let shell = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: 0.03, height: 0.085))
            let shellMat = SCNMaterial()
            shellMat.diffuse.contents = NSColor.black
            shellMat.emission.contents = NSColor(calibratedRed: 0.98, green: 0.45, blue: 0.10, alpha: 1)
            shellMat.lightingModel = .constant
            shell.geometry!.firstMaterial = shellMat
            shell.opacity = 0.85
            shell.categoryBitMask = 2
            flame.addChildNode(shell)
            let core = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: 0.016, height: 0.055))
            let coreMat = SCNMaterial()
            coreMat.diffuse.contents = NSColor.black
            coreMat.emission.contents = NSColor(calibratedRed: 1.0, green: 0.85, blue: 0.35, alpha: 1)
            coreMat.lightingModel = .constant
            core.geometry!.firstMaterial = coreMat
            core.position = SCNVector3(0, -0.008, 0)
            core.categoryBitMask = 2
            flame.addChildNode(core)
            flame.position = SCNVector3(tip.0 + 0.015, tip.1 + 0.07, tip.2 + 0.02)
            let flicker = SCNAction.repeatForever(.sequence([
                .scale(to: 1.15, duration: 0.22),
                .scale(to: 0.92, duration: 0.28),
                .scale(to: 1.08, duration: 0.18),
                .scale(to: 1.0, duration: 0.24)]))
            flame.runAction(flicker)
            d.addChildNode(flame)
            creatureFlame = flame
        }

        // BACK SPINES — a soft ridge down the spine.
        for i in 0..<4 {
            let spine = cone(0.02, 0.05 - CGFloat(i) * 0.006, Self.cWing)
            spine.scale = SCNVector3(1, 1, 0.4)
            spine.position = SCNVector3(0, 0.30 - CGFloat(i) * 0.045, -0.11 - CGFloat(i) * 0.006)
            spine.eulerAngles = SCNVector3(-0.5, 0, 0)
            d.addChildNode(spine)
        }

        // WINGS — small orange-membrane bat wings on the upper back.
        for side: CGFloat in [-1, 1] {
            let wing = wingNode()
            wing.position = SCNVector3(0.10 * side, 0.33, -0.085)
            wing.eulerAngles = SCNVector3(0.35, -1.0 * side, 0.5 * side)
            wing.scale = SCNVector3(0.82 * side, 0.82, 1)
            d.addChildNode(wing)
            creatureWings.append(wing)
        }

        // LEGS — chunky thighs splayed out to seated feet with toes.
        for side: CGFloat in [-1, 1] {
            let thigh = limb(SCNVector3(0.075 * side, 0.135, 0.01),
                             SCNVector3(0.115 * side, 0.05, 0.10), 0.058, Self.cTeal)
            d.addChildNode(thigh)
            let foot = ball(0.052, Self.cTeal)
            foot.scale = SCNVector3(1.05, 0.66, 1.5)
            foot.position = SCNVector3(0.112 * side, 0.03, 0.15)
            d.addChildNode(foot)
            for t in -1...1 {
                let claw = cone(0.009, 0.022, Self.cHorn)
                claw.eulerAngles.x = -1.3
                claw.position = SCNVector3(0.112 * side + CGFloat(t) * 0.024, 0.022, 0.212)
                d.addChildNode(claw)
            }
        }

        // ARMS — a shoulder, a bent elbow and little hands resting on the
        // belly (both hands meet near the middle, like the reference).
        for side: CGFloat in [-1, 1] {
            let shoulder = ball(0.046, Self.cTeal)
            shoulder.position = SCNVector3(0.10 * side, 0.255, 0.03)
            d.addChildNode(shoulder)
            let elbow = SCNVector3(0.10 * side, 0.15, 0.10)   // tucked in, not flared out
            let upper = limb(SCNVector3(0.10 * side, 0.25, 0.04), elbow, 0.034, Self.cTeal)
            d.addChildNode(upper)
            let handPos = SCNVector3(0.05 * side, 0.115, 0.16)
            let fore = limb(elbow, handPos, 0.031, Self.cTeal)
            d.addChildNode(fore)
            let hand = ball(0.044, Self.cTeal)
            hand.scale = SCNVector3(1.05, 0.85, 1.05)
            hand.position = handPos
            d.addChildNode(hand)
            for t in -1...1 {
                let claw = cone(0.008, 0.018, Self.cHorn)
                claw.eulerAngles.x = -0.6
                claw.position = SCNVector3(handPos.x + CGFloat(t) * 0.018 * side, handPos.y + 0.005, handPos.z + 0.036)
                d.addChildNode(claw)
            }
        }

        // HEAD GROUP — big chibi head; this node tilts/nods with state.
        let headGroup = SCNNode()
        headGroup.position = SCNVector3(0, 0.33, 0.015)
        d.addChildNode(headGroup)
        creatureHead = headGroup

        let head = ball(0.155, Self.cTeal)
        head.scale = SCNVector3(1.06, 1.0, 1.0)
        head.position = SCNVector3(0, 0.12, 0)
        headGroup.addChildNode(head)

        // Cheeks — soft blush that brightens with mood.
        for side: CGFloat in [-1, 1] {
            let cheek = ball(0.03, Self.cCheek)
            cheek.scale = SCNVector3(1, 0.7, 0.5)
            cheek.position = SCNVector3(0.095 * side, 0.075, 0.115)
            cheek.opacity = 0.55
            headGroup.addChildNode(cheek)
            creatureCheeks.append(cheek)
        }

        // EYES — big, forward, two highlights each. Iris recolors on mood.
        for side: CGFloat in [-1, 1] {
            let eye = SCNNode()
            eye.position = SCNVector3(0.062 * side, 0.135, 0.118)
            eye.eulerAngles = SCNVector3(0, 0.22 * side, 0)
            let sclera = ball(0.052, NSColor(calibratedWhite: 0.98, alpha: 1), shiny: true)
            sclera.scale = SCNVector3(0.92, 1.08, 0.6)
            eye.addChildNode(sclera)
            let iris = ball(0.038, Self.cIris, shiny: true)
            iris.scale = SCNVector3(0.88, 1.02, 0.7)
            iris.position = SCNVector3(0.004 * side, 0.004, 0.03)
            eye.addChildNode(iris)
            creaturePupils.append(iris)
            let pupil = ball(0.022, NSColor(calibratedRed: 0.09, green: 0.07, blue: 0.10, alpha: 1), shiny: true)
            pupil.scale = SCNVector3(0.9, 1.05, 0.6)
            pupil.position = SCNVector3(0.004 * side, 0.002, 0.052)
            eye.addChildNode(pupil)
            let h1 = lit(0.015, NSColor.white); h1.position = SCNVector3(0.014 * side, 0.02, 0.062)
            let h2 = lit(0.008, NSColor.white); h2.position = SCNVector3(-0.01 * side, -0.008, 0.062)
            eye.addChildNode(h1); eye.addChildNode(h2)
            headGroup.addChildNode(eye)
            creatureEyes.append(eye)
        }

        // Brow ridges — a tiny cute angle above each eye.
        for side: CGFloat in [-1, 1] {
            let brow = ball(0.028, Self.cTeal)
            brow.scale = SCNVector3(1.3, 0.35, 0.5)
            brow.position = SCNVector3(0.062 * side, 0.185, 0.11)
            brow.eulerAngles = SCNVector3(0, 0, -0.2 * side)
            headGroup.addChildNode(brow)
        }

        // SNOUT + MOUTH.
        let snout = ball(0.075, Self.cTeal)
        snout.scale = SCNVector3(1.25, 0.8, 1.05)
        snout.position = SCNVector3(0, 0.05, 0.135)
        headGroup.addChildNode(snout)
        for side: CGFloat in [-1, 1] {
            let nostril = lit(0.006, NSColor(calibratedWhite: 0.1, alpha: 1))
            nostril.position = SCNVector3(0.02 * side, 0.075, 0.205)
            headGroup.addChildNode(nostril)
        }

        // Dark mouth interior + tongue (revealed when the jaw drops).
        let cavity = ball(0.05, Self.cMouth)
        cavity.scale = SCNVector3(1.1, 0.75, 0.7)
        cavity.position = SCNVector3(0, 0.0, 0.11)
        headGroup.addChildNode(cavity)
        let tongue = ball(0.03, Self.cTongue)
        tongue.scale = SCNVector3(1.0, 0.5, 1.1)
        tongue.position = SCNVector3(0, -0.015, 0.135)
        headGroup.addChildNode(tongue)

        // Lower jaw — hinged at the back, swings open with her voice.
        let jaw = SCNNode()
        jaw.position = SCNVector3(0, 0.01, 0.055)
        let chin = ball(0.062, Self.cTeal)
        chin.scale = SCNVector3(1.12, 0.52, 0.92)
        chin.position = SCNVector3(0, -0.016, 0.078)
        jaw.addChildNode(chin)
        headGroup.addChildNode(jaw)
        creatureJaw = jaw

        // Smile line — a dark upturned crescent shown when the mouth is
        // closed (idle/listening); it fades out as the jaw opens.
        let smile = makeSmile()
        headGroup.addChildNode(smile)
        creatureSmile = smile

        // HORNS — two little cream horns swept back.
        for side: CGFloat in [-1, 1] {
            let horn = cone(0.02, 0.07, Self.cHorn)
            horn.position = SCNVector3(0.055 * side, 0.245, -0.01)
            horn.eulerAngles = SCNVector3(-0.6, 0, -0.25 * side)
            headGroup.addChildNode(horn)
        }

        // EARS — big pointed fins with an orange inner.
        for side: CGFloat in [-1, 1] {
            let ear = cone(0.05, 0.12, Self.cTeal)
            ear.scale = SCNVector3(1, 1, 0.32)
            ear.position = SCNVector3(0.14 * side, 0.17, -0.02)
            ear.eulerAngles = SCNVector3(-0.15, 0, -0.7 * side)
            headGroup.addChildNode(ear)
            let inner = cone(0.03, 0.08, Self.cWing)
            inner.scale = SCNVector3(1, 1, 0.28)
            inner.position = SCNVector3(0.14 * side, 0.165, -0.005)
            inner.eulerAngles = SCNVector3(-0.15, 0, -0.7 * side)
            headGroup.addChildNode(inner)
        }

        // CREST — a low soft finned mohawk along the crown (thin fins,
        // front to back), not one tall spike.
        let crest: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [   // z, height, radius, tiltX, y
            (0.075, 0.095, 0.032, 0.30, 0.278),
            (0.02,  0.125, 0.044, -0.02, 0.318),
            (-0.045, 0.125, 0.040, -0.28, 0.305),
            (-0.105, 0.115, 0.032, -0.48, 0.272)]
        for c in crest {
            let fin = cone(c.2, c.1, Self.cCrest)
            fin.scale = SCNVector3(0.42, 1, 0.95)
            fin.position = SCNVector3(0, c.4, c.0)
            fin.eulerAngles = SCNVector3(c.3, 0, 0)
            headGroup.addChildNode(fin)
        }

        d.scale = SCNVector3(sizeK, sizeK, sizeK)
        d.position = SCNVector3(0, 1.19, 0)
        // Slight 3/4 stance: fans the crest fins apart on screen and
        // gives the whole pose depth (a dead-front view stacks the
        // midline comb into a single spike).
        d.eulerAngles.y = env["AITVARAS_DRAGON_YAW"].flatMap(Double.init).map { CGFloat($0) } ?? 0.30
        rootContainer.addChildNode(d)

        // Lighting — bright, even, warm; on the creature's own category so
        // the room's mood lights don't muddy the cartoon look.
        let amb = SCNNode(); amb.light = SCNLight(); amb.light!.type = .ambient
        amb.light!.intensity = 560; amb.light!.categoryBitMask = 2
        rootContainer.addChildNode(amb)
        let key = SCNNode(); key.light = SCNLight(); key.light!.type = .directional
        key.light!.intensity = 430
        key.light!.color = NSColor(calibratedRed: 1, green: 0.97, blue: 0.92, alpha: 1)
        key.light!.categoryBitMask = 2
        key.eulerAngles = SCNVector3(-0.55, 0.35, 0)
        rootContainer.addChildNode(key)
        let fill = SCNNode(); fill.light = SCNLight(); fill.light!.type = .directional
        fill.light!.intensity = 150
        fill.light!.color = NSColor(calibratedRed: 0.9, green: 0.95, blue: 1, alpha: 1)
        fill.light!.categoryBitMask = 2
        fill.eulerAngles = SCNVector3(-0.1, -0.7, 0)
        rootContainer.addChildNode(fill)
        scene?.lightingEnvironment.intensity = 0.0

        // Mood aura on the floor + soft contact shadow.
        let aura = SCNNode(geometry: SCNPlane(width: 0.62, height: 0.42))
        let auraMat = SCNMaterial(); auraMat.lightingModel = .constant
        auraMat.diffuse.contents = Self.radialGlowImage(Self.cWing)
        auraMat.blendMode = .add; auraMat.isDoubleSided = true
        auraMat.writesToDepthBuffer = false
        aura.geometry!.materials = [auraMat]
        aura.eulerAngles.x = -.pi / 2
        aura.position = SCNVector3(0, 1.192, 0)
        aura.renderingOrder = 10; aura.opacity = 0.45
        rootContainer.addChildNode(aura)
        dragonAura = aura

        let shadow = SCNNode(geometry: SCNPlane(width: 0.5, height: 0.34))
        let shadowMat = SCNMaterial(); shadowMat.lightingModel = .constant
        shadowMat.diffuse.contents = Self.radialShadowImage()
        shadowMat.isDoubleSided = true; shadowMat.blendMode = .alpha
        shadow.geometry!.materials = [shadowMat]
        shadow.eulerAngles.x = -.pi / 2
        shadow.position = SCNVector3(0, 1.191, 0)
        rootContainer.addChildNode(shadow)

        frameCameraOnCreature()
        applyCreatureState(.idle)
    }

    /// A small scalloped bat-wing membrane (orange) with teal finger-bones.
    private func wingNode() -> SCNNode {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0, y: 0))
        path.line(to: NSPoint(x: 0.02, y: 0.16))
        path.line(to: NSPoint(x: 0.075, y: 0.08))
        path.line(to: NSPoint(x: 0.075, y: 0.14))
        path.line(to: NSPoint(x: 0.13, y: 0.075))
        path.line(to: NSPoint(x: 0.125, y: 0.12))
        path.line(to: NSPoint(x: 0.17, y: 0.045))
        path.line(to: NSPoint(x: 0.12, y: -0.01))
        path.line(to: NSPoint(x: 0.05, y: -0.02))
        path.close()
        let node = SCNNode()
        let under = SCNShape(path: path, extrusionDepth: 0.004)
        under.firstMaterial = skinMat(Self.cWing)
        let underNode = SCNNode(geometry: under)
        underNode.scale = SCNVector3(1.12, 1.12, 1)
        underNode.position = SCNVector3(0.004, -0.004, -0.003)
        underNode.categoryBitMask = 2
        node.addChildNode(underNode)
        let top = SCNShape(path: path, extrusionDepth: 0.006)
        top.firstMaterial = skinMat(Self.cTeal)
        let topNode = SCNNode(geometry: top)
        topNode.categoryBitMask = 2
        node.addChildNode(topNode)
        return node
    }

    /// An upturned smile drawn as a row of overlapping dark beads — a
    /// depth-independent decal that reliably reads on the curved snout.
    private func makeSmile() -> SCNNode {
        let smile = SCNNode()
        let n = 11
        for i in 0..<n {
            let u = CGFloat(i) / CGFloat(n - 1) * 2 - 1   // -1 … 1
            let x = u * 0.05
            let y = 0.036 - 0.03 * (1 - u * u)            // corners up, middle down = smile
            let dot = SCNNode(geometry: SCNSphere(radius: 0.0085))
            let m = SCNMaterial()
            m.diffuse.contents = Self.cMouth
            m.lightingModel = .constant
            m.readsFromDepthBuffer = false                // sits on top of the snout
            m.writesToDepthBuffer = false
            dot.geometry!.firstMaterial = m
            dot.scale = SCNVector3(1, 1, 0.4)
            dot.position = SCNVector3(x, y, 0.208 - abs(u) * 0.012)
            dot.renderingOrder = 20
            dot.categoryBitMask = 2
            smile.addChildNode(dot)
        }
        return smile
    }

    private func frameCameraOnCreature() {
        guard let scene else { return }
        scene.rootNode.childNodes.filter { $0.camera != nil }.forEach { $0.removeFromParentNode() }
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera!.fieldOfView = 32
        cameraNode.camera!.zNear = 0.01
        cameraNode.camera!.zFar = 50
        cameraNode.position = SCNVector3(0, 1.55, 1.72)
        cameraNode.look(at: SCNVector3(0, 1.47, 0))
        scene.rootNode.addChildNode(cameraNode)
        // The view may have already rendered once and locked onto a
        // default POV before this camera existed.
        view?.pointOfView = cameraNode
    }

    /// The cartoon dragon's "expression": eye shape, a curious head-tilt,
    /// cheek blush and the floor aura shift per state. Body colours stay
    /// constant (teal + orange) — mood reads through the face and glow.
    private func applyCreatureState(_ state: CharacterState) {
        let eyeScale: SCNVector3
        let auraColor: NSColor
        let cheek: CGFloat
        let headEuler: SCNVector3
        switch state {
        case .idle:
            eyeScale = SCNVector3(1, 1, 1)
            auraColor = NSColor(calibratedRed: 0.95, green: 0.55, blue: 0.22, alpha: 1)   // ember
            cheek = 0.5
            headEuler = SCNVector3(0, 0, 0)
        case .listening:
            eyeScale = SCNVector3(1.08, 1.12, 1)     // wide, attentive
            auraColor = NSColor(calibratedRed: 1.0, green: 0.76, blue: 0.30, alpha: 1)    // bright gold
            cheek = 0.72
            headEuler = SCNVector3(-0.04, 0, 0.14)   // curious head-tilt toward the user
        case .thinking:
            eyeScale = SCNVector3(1, 0.72, 1)        // narrowed, pensive
            auraColor = NSColor(calibratedRed: 0.85, green: 0.60, blue: 0.85, alpha: 1)   // violet shimmer
            cheek = 0.5
            headEuler = SCNVector3(-0.1, 0.13, 0)    // glance up and aside
        case .speaking:
            eyeScale = SCNVector3(1.03, 1.03, 1)
            auraColor = NSColor(calibratedRed: 1.0, green: 0.45, blue: 0.18, alpha: 1)    // flame orange
            cheek = 0.66
            headEuler = SCNVector3(0, 0, 0)
        }
        creatureBaseHeadEuler = headEuler
        creatureEyeBaseScale = eyeScale
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.3
        for eye in creatureEyes { eye.scale = eyeScale }
        for iris in creaturePupils {
            iris.geometry?.firstMaterial?.emission.contents = auraColor
            iris.geometry?.firstMaterial?.emission.intensity = 0.14
        }
        for c in creatureCheeks { c.opacity = cheek }
        dragonAura?.geometry?.firstMaterial?.diffuse.contents = Self.radialGlowImage(auraColor)
        creatureHead?.eulerAngles = headEuler
        SCNTransaction.commit()
    }

    private func installGLTF(_ asset: GLTFAsset) {
        scene?.lightingEnvironment.intensity = 0.09   // dragon mode lowers it
        let source = GLTFSCNSceneSource(asset: asset)
        guard let avatarScene = source.defaultScene else {
            installPlaceholder()
            return
        }
        let avatarRoot = SCNNode()
        for child in avatarScene.rootNode.childNodes {
            avatarRoot.addChildNode(child)
        }
        rootContainer.addChildNode(avatarRoot)

        // Collect morph targets (RPM ships the 52 ARKit blendshapes).
        avatarRoot.enumerateHierarchy { node, _ in
            if node.morpher != nil { morphNodes.append(node) }
            if node.name?.lowercased().contains("head") == true, headNode == nil {
                headNode = node
            }
        }

        applyHolographicRim(to: avatarRoot)
        frameCamera(on: avatarRoot, headBias: true)
        addBreathing(to: avatarRoot)
    }

    private func installPlaceholder() {
        // Neutral mannequin bust — deliberately plain; the real face is
        // the user's imported avatar.
        let bust = SCNNode()

        let matte = SCNMaterial()
        matte.diffuse.contents = NSColor(calibratedWhite: 0.82, alpha: 1)
        matte.roughness.contents = 0.7

        let head = SCNNode(geometry: SCNSphere(radius: 0.09))
        head.geometry?.materials = [matte]
        head.position = SCNVector3(0, 0.32, 0)
        head.scale = SCNVector3(0.88, 1.05, 0.92)
        head.name = "Head"
        bust.addChildNode(head)

        let eyeGeometry = SCNSphere(radius: 0.009)
        let eyeMaterial = SCNMaterial()
        eyeMaterial.diffuse.contents = NSColor(calibratedWhite: 0.15, alpha: 1)
        eyeGeometry.materials = [eyeMaterial]
        for x in [-0.032, 0.032] {
            let eye = SCNNode(geometry: eyeGeometry)
            eye.position = SCNVector3(x, 0.335, 0.075)
            bust.addChildNode(eye)
        }

        let neck = SCNNode(geometry: SCNCylinder(radius: 0.028, height: 0.07))
        neck.geometry?.materials = [matte]
        neck.position = SCNVector3(0, 0.22, 0)
        bust.addChildNode(neck)

        let torsoGeometry = SCNBox(width: 0.24, height: 0.16, length: 0.12, chamferRadius: 0.05)
        torsoGeometry.materials = [matte]
        let torso = SCNNode(geometry: torsoGeometry)
        torso.position = SCNVector3(0, 0.1, 0)
        bust.addChildNode(torso)

        let collarGeometry = SCNTorus(ringRadius: 0.055, pipeRadius: 0.004)
        let collarMaterial = SCNMaterial()
        collarMaterial.emission.contents = NSColor(calibratedRed: 0.4, green: 0.9, blue: 0.82, alpha: 1)
        collarMaterial.diffuse.contents = NSColor.black
        collarGeometry.materials = [collarMaterial]
        let collar = SCNNode(geometry: collarGeometry)
        collar.position = SCNVector3(0, 0.245, 0)
        bust.addChildNode(collar)

        headNode = head
        rootContainer.addChildNode(bust)
        frameCamera(on: bust, headBias: false)
        addBreathing(to: bust)
    }

    private func frameCamera(on node: SCNNode, headBias: Bool) {
        guard let scene else { return }
        scene.rootNode.childNodes.filter { $0.camera != nil }.forEach { $0.removeFromParentNode() }

        let (minVec, maxVec) = node.boundingBox
        let height = maxVec.y - minVec.y
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera!.fieldOfView = headBias ? 34 : 28
        // Human-scale scene in meters: the default zNear of 1.0 would
        // clip everything closer than 1m — i.e. the entire figure.
        cameraNode.camera!.zNear = 0.01
        cameraNode.camera!.zFar = 50

        if headBias {
            // Head-and-shoulders, framed slightly wider so the room wall,
            // window glow and bookshelf read around her.
            // Portrait: head-and-shoulders, room only peeking at the edges.
            let headY = minVec.y + height * 0.85
            cameraNode.position = SCNVector3(0, headY - 0.04, CGFloat(height) * 0.66)
            cameraNode.look(at: SCNVector3(0, headY - 0.06, 0))
        } else {
            let centerY = (minVec.y + maxVec.y) / 2 + 0.08
            cameraNode.position = SCNVector3(0, centerY, 0.85)
            cameraNode.look(at: SCNVector3(0, centerY, 0))
        }
        scene.rootNode.addChildNode(cameraNode)
        // Explicitly switch away from any camera embedded in the avatar
        // asset. The tighter portrait camera should always win.
        view?.pointOfView = cameraNode
    }

    private func addBreathing(to node: SCNNode) {
        let up = SCNAction.moveBy(x: 0, y: 0.004, z: 0, duration: 2.2)
        up.timingMode = .easeInEaseOut
        let down = up.reversed()
        node.runAction(.repeatForever(.sequence([up, down])))
    }

    // MARK: Animation state

    func apply(state: CharacterState, mouth: Float) {
        if state != currentState {
            transition(to: state)
        }
        smoothedMouth += (mouth - smoothedMouth) * 0.35
        if usingCreature {
            // Her voice opens the jaw (real mouth movement), hides the
            // closed-mouth smile, pulses the floor aura, and — while
            // speaking — adds a gentle nod on top of the state pose.
            let m = CGFloat(min(smoothedMouth, 1))
            creatureJaw?.eulerAngles.x = m * 0.5
            creatureSmile?.opacity = 1 - min(m * 2.4, 1)
            dragonAura?.opacity = 0.45 + m * 0.5
            creatureFlame?.opacity = 0.7 + m * 0.3
            if currentState == .speaking, let head = creatureHead {
                head.eulerAngles = SCNVector3(
                    creatureBaseHeadEuler.x + m * 0.09,
                    creatureBaseHeadEuler.y,
                    creatureBaseHeadEuler.z)
            }
            return
        }
        setMorph("jawOpen", weight: CGFloat(min(smoothedMouth * 0.8, 0.65)))
        setMorph("mouthFunnel", weight: CGFloat(min(smoothedMouth * 0.2, 0.2)))
    }

    private func transition(to state: CharacterState) {
        currentState = state
        if usingCreature { applyCreatureState(state) }
        guard let headNode else { return }
        headNode.removeAction(forKey: "stateMotion")
        switch state {
        case .idle:
            SCNTransaction.begin(); SCNTransaction.animationDuration = 0.6
            headNode.eulerAngles = SCNVector3(0, 0, 0)
            SCNTransaction.commit()
        case .listening:
            // Attentive: slight head tilt toward the user.
            SCNTransaction.begin(); SCNTransaction.animationDuration = 0.5
            headNode.eulerAngles = SCNVector3(0.06, 0, 0.05)
            SCNTransaction.commit()
        case .thinking:
            // Pensive slow sway.
            let left = SCNAction.rotateTo(x: 0.04, y: 0.12, z: 0, duration: 1.6)
            left.timingMode = .easeInEaseOut
            let right = SCNAction.rotateTo(x: 0.04, y: -0.12, z: 0, duration: 1.6)
            right.timingMode = .easeInEaseOut
            headNode.runAction(.repeatForever(.sequence([left, right])), forKey: "stateMotion")
        case .speaking:
            SCNTransaction.begin(); SCNTransaction.animationDuration = 0.4
            headNode.eulerAngles = SCNVector3(0.02, 0, 0)
            SCNTransaction.commit()
        }
    }

    private func startBlinking() {
        blinkTask?.cancel()
        blinkTask = Task { [weak self] in
            while !Task.isCancelled {
                let pause = Double.random(in: 2.2...5.0)
                try? await Task.sleep(for: .seconds(pause))
                await self?.blink()
            }
        }
    }

    private func blink() async {
        if usingCreature {
            guard currentState != .thinking else { return }   // eyes already narrowed
            // Squash the big eyes shut, then restore the state's shape.
            SCNTransaction.begin(); SCNTransaction.animationDuration = 0.07
            for eye in creatureEyes {
                eye.scale = SCNVector3(creatureEyeBaseScale.x, creatureEyeBaseScale.y * 0.08, creatureEyeBaseScale.z)
            }
            SCNTransaction.commit()
            try? await Task.sleep(for: .milliseconds(100))
            SCNTransaction.begin(); SCNTransaction.animationDuration = 0.12
            for eye in creatureEyes { eye.scale = creatureEyeBaseScale }
            SCNTransaction.commit()
            return
        }
        setMorph("eyeBlinkLeft", weight: 1, duration: 0.07)
        setMorph("eyeBlinkRight", weight: 1, duration: 0.07)
        try? await Task.sleep(for: .milliseconds(110))
        setMorph("eyeBlinkLeft", weight: 0, duration: 0.12)
        setMorph("eyeBlinkRight", weight: 0, duration: 0.12)
    }

    private func setMorph(_ name: String, weight: CGFloat, duration: TimeInterval = 0.05) {
        guard !morphNodes.isEmpty else { return }
        SCNTransaction.begin()
        SCNTransaction.animationDuration = duration
        for node in morphNodes {
            node.morpher?.setWeight(weight, forTargetNamed: name)
        }
        SCNTransaction.commit()
    }
}
