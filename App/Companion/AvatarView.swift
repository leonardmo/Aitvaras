import SwiftUI
import SceneKit
import GLTFKit2
import AitvarasCore

/// SceneKit otherwise advertises an opaque backing layer even when its
/// background color is clear, which prevents the desktop from showing
/// through translucent room geometry.
final class TransparentSceneView: SCNView {
    var onVisibilityChange: (() -> Void)?
    private var stillView: NSImageView?
    override var isOpaque: Bool { false }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); onVisibilityChange?() }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); onVisibilityChange?() }
    override func viewDidHide() { super.viewDidHide(); onVisibilityChange?() }
    override func viewDidUnhide() { super.viewDidUnhide(); onVisibilityChange?() }

    /// A cached, alpha-preserving still keeps the companion visible while
    /// there is no scene attached to the Metal renderer. Pause flags alone
    /// do not reliably stop all SceneKit render callbacks on every OS.
    func holdStillFrame() {
        guard scene != nil else { return }
        let image = super.snapshot()
        let preview = stillView ?? NSImageView(frame: bounds)
        preview.autoresizingMask = [.width, .height]
        preview.imageScaling = .scaleAxesIndependently
        preview.image = image
        preview.isHidden = false
        if preview.superview == nil { addSubview(preview) }
        stillView = preview
        scene = nil
    }

    func showLiveScene() { stillView?.isHidden = true }
    func clearStillFrame() { stillView?.removeFromSuperview(); stillView = nil }
    override func snapshot() -> NSImage {
        if scene == nil, let image = stillView?.image { return image }
        return super.snapshot()
    }
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
        view.antialiasingMode = .multisampling2X
        view.autoenablesDefaultLighting = false
        view.rendersContinuously = false
        view.isPlaying = false
        view.preferredFramesPerSecond = 30
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        context.coordinator.apply(state: model.characterState, mouth: model.mouthLevel)
    }

    static func dismantleNSView(_ view: SCNView, coordinator: AvatarController) {
        (view as? TransparentSceneView)?.onVisibilityChange = nil
        coordinator.detach()
    }
}

struct AvatarRenderDiagnostics {
    let decision: AvatarRenderPolicy.Decision
    let visibility: AvatarRenderPolicy.Visibility
    let isPlaying: Bool
    let rendersContinuously: Bool
    let isScenePaused: Bool
    let blinkTaskActive: Bool
    let timeOfDayTaskActive: Bool
    let burstTaskActive: Bool
    let mailTaskActive: Bool
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
    private var burstTask: Task<Void, Never>?
    private var mailTask: Task<Void, Never>?
    private var mailEnvelope: SCNNode?
    private let lifecycle = AvatarRenderLifecycle()
    private var visibility = AvatarRenderPolicy.Visibility()
    private var hasTransientAnimation = false
    private var burstDeadline: ContinuousClock.Instant?
    private var notificationObservers: [NSObjectProtocol] = []
    private var loadGeneration: UInt64 = 0
    private var latestMouth: Float = 0
    private var cachedPointOfView: SCNNode?
    private var windowMaterial: SCNMaterial?
    private var windowLight: SCNNode?
    private var currentState: CharacterState = .idle
    private var smoothedMouth: Float = 0

    isolated deinit { detach() }

    /// Test-mode observation without coupling diagnostics to one asset's
    /// skeleton node names.
    func diagnosticHeadPosition() -> SCNVector3? {
        (creatureHead ?? headNode)?.presentation.worldPosition
    }

    func diagnosticRenderDecision() -> AvatarRenderPolicy.Decision {
        // This runtime has static listening/thinking poses. Render their
        // transitions and blinks, not an otherwise unchanged 30 FPS loop.
        let schedulingState: CharacterState = usingRuntimeDragon && currentState != .speaking ? .idle : currentState
        return AvatarRenderPolicy.decision(visibility: visibility, state: schedulingState, hasTransientAnimation: hasTransientAnimation)
    }

    var diagnosticVisualTaskCount: Int {
        [blinkTask, timeOfDayTask, burstTask, mailTask].compactMap { $0 }.count
    }

    func diagnosticRendering() -> AvatarRenderDiagnostics {
        AvatarRenderDiagnostics(
            decision: diagnosticRenderDecision(), visibility: visibility,
            isPlaying: view?.isPlaying == true,
            rendersContinuously: view?.rendersContinuously == true,
            isScenePaused: scene?.isPaused != false,
            blinkTaskActive: blinkTask != nil, timeOfDayTaskActive: timeOfDayTask != nil,
            burstTaskActive: burstTask != nil, mailTaskActive: mailTask != nil)
    }

    /// Explicit still-image preparation for the headless avatarshot harness.
    /// This never starts rendering, animation actions, or visual tasks.
    func diagnosticApplyStaticPose(state: CharacterState, mouth: Float) {
        guard !visibility.canRender else { return }
        latestMouth = state == .speaking ? min(max(mouth, 0), 1) : 0
        smoothedMouth = latestMouth
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        transition(to: state, animated: false)
        updateMouth(latestMouth)
        SCNTransaction.commit()
    }

    // Authored dragon mesh — driven by the same state machine as the human
    // avatar through named GLB nodes rather than a skeletal rig.
    private var usingCreature = false
    private var usingRuntimeDragon = false
    private var creatureEyes: [SCNNode] = []          // whole eye groups (blink by Y-scale)
    private var creaturePupils: [SCNNode] = []        // dark iris — faint mood glow
    private var creatureJaw: SCNNode?                 // lower jaw — opens with her voice
    private var creatureSmile: SCNNode?               // smile line — shown when mouth is closed
    private var creatureMouthInterior: SCNNode?       // revealed as the jaw opens
    private var creatureTongue: SCNNode?
    private var creatureWings: [SCNNode] = []
    private var creatureCheeks: [SCNNode] = []        // blush — brightens with mood
    private var creatureEyeBaseScale = SCNVector3(1, 1, 1)   // per-state; blink restores to it
    private var creatureFlame: SCNNode?               // tail flame — flares with her voice

    func attach(to view: SCNView) {
        detach()
        self.view = view
        (view as? TransparentSceneView)?.onVisibilityChange = { [weak self] in self?.refreshVisibility() }
        let scene = SCNScene()
        scene.background.contents = NSColor.clear
        self.scene = scene
        view.scene = scene
        scene.isPaused = true

        setupLights(scene)
        setupRoom(scene)
        loadAvatar()
        lifecycle.onChange = { [weak self] visibility in self?.visibilityDidChange(visibility) }
        lifecycle.attach(to: view)

        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: .aitvarasAvatarChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.loadAvatar() }
        })
        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: .aitvarasMailArrived, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.playMailDrop() }
        })
    }

    func refreshVisibility() { lifecycle.refresh() }

    func detach() {
        loadGeneration &+= 1
        lifecycle.stop()
        lifecycle.onChange = nil
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        notificationObservers.removeAll()
        cancelVisualTasks()
        view?.isPlaying = false
        view?.rendersContinuously = false
        scene?.isPaused = true
        (view as? TransparentSceneView)?.onVisibilityChange = nil
        (view as? TransparentSceneView)?.clearStillFrame()
        view?.scene = nil
        view = nil
        scene = nil
        cachedPointOfView = nil
        visibility = .init()
    }

    private func visibilityDidChange(_ value: AvatarRenderPolicy.Visibility) {
        let wasVisible = visibility.canRender
        visibility = value
        guard value.canRender else {
            cancelVisualTasks()
            updateRenderScheduling()
            return
        }
        if !wasVisible {
            updateTimeOfDay(animated: false)
            transition(to: currentState)
            updateMouth(latestMouth)
            startBlinking()
            startTimeOfDayUpdates()
            requestRenderBurst(seconds: 0.65)
        }
        updateRenderScheduling()
        view?.needsDisplay = true
    }

    private func cancelVisualTasks() {
        blinkTask?.cancel(); blinkTask = nil
        timeOfDayTask?.cancel(); timeOfDayTask = nil
        burstTask?.cancel(); burstTask = nil
        mailTask?.cancel(); mailTask = nil
        mailEnvelope?.removeAllActions()
        mailEnvelope?.removeFromParentNode(); mailEnvelope = nil
        hasTransientAnimation = false
        burstDeadline = nil
        resetBlink()
    }

    private func updateRenderScheduling() {
        let decision = diagnosticRenderDecision()
        let animated = decision.mode == .animated
        // Never assign zero to SceneKit's FPS property: it means the display's
        // maximum refresh rate. The two flags actually stop its render loop.
        view?.preferredFramesPerSecond = 30
        view?.rendersContinuously = animated
        view?.isPlaying = animated
        scene?.isPaused = !animated
        if animated {
            if view?.scene == nil {
                view?.scene = scene
                if let cachedPointOfView { view?.pointOfView = cachedPointOfView }
            }
            (view as? TransparentSceneView)?.showLiveScene()
        } else {
            if let camera = view?.pointOfView { cachedPointOfView = camera }
            if decision.mode == .onDemand, let transparent = view as? TransparentSceneView {
                transparent.holdStillFrame()
            } else {
                // Hidden/sleeping: no capture or GPU readback either.
                view?.scene = nil
            }
        }
    }

    private func requestRenderBurst(seconds: Double) {
        guard visibility.canRender else { return }
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        if let burstDeadline, burstDeadline >= deadline { return }
        burstTask?.cancel()
        burstDeadline = deadline
        hasTransientAnimation = true
        updateRenderScheduling()
        burstTask = Task { [weak self] in
            do { try await ContinuousClock().sleep(until: deadline) }
            catch { return }
            guard let self, !Task.isCancelled else { return }
            self.burstTask = nil
            self.burstDeadline = nil
            self.hasTransientAnimation = false
            self.updateRenderScheduling()
        }
    }

    private func startTimeOfDayUpdates() {
        timeOfDayTask?.cancel()
        guard !usingRuntimeDragon else { timeOfDayTask = nil; return }
        timeOfDayTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(300)) }
                catch { return }
                guard let self, self.visibility.canRender, !Task.isCancelled else { return }
                self.requestRenderBurst(seconds: 3.1)
                self.updateTimeOfDay(animated: true)
            }
        }
    }

    // MARK: Virtual room — a quiet study diorama behind/around her.

    private func setupRoom(_ scene: SCNScene) {
        let room = SCNNode()
        room.name = "Room"

        func matte(_ color: NSColor, constant: Bool = false) -> SCNMaterial {
            let m = SCNMaterial()
            m.diffuse.contents = color
            if constant {
                m.lightingModel = .constant
            } else {
                m.lightingModel = .physicallyBased
                m.roughness.contents = 0.72
                m.metalness.contents = 0
            }
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
        lamp.light!.intensity = 4
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
        windowLight.light!.intensity = 2
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
        guard visibility.canRender, !usingRuntimeDragon, let scene else { return }
        mailTask?.cancel()
        mailEnvelope?.removeFromParentNode()
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
        mailEnvelope = envelope
        requestRenderBurst(seconds: 1.35)
        envelope.runAction(.sequence([appear, fall, settle]))
        // Keep the settled envelope static during its rest; a SceneKit wait
        // action would require rendering all fourteen otherwise idle seconds.
        mailTask = Task { [weak self, weak envelope] in
            do { try await Task.sleep(for: .seconds(15.22)) }
            catch { return }
            guard let self, let envelope, self.visibility.canRender, !Task.isCancelled else { return }
            self.requestRenderBurst(seconds: 1.3)
            envelope.runAction(.sequence([.fadeOut(duration: 1.2), .removeFromParentNode()]),
                               forKey: "mailFade", completionHandler: {})
            do { try await Task.sleep(for: .seconds(1.3)) }
            catch { return }
            guard !Task.isCancelled else { return }
            self.mailEnvelope = nil
            self.mailTask = nil
        }
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
        scene.lightingEnvironment.intensity = 0.045

        let key = SCNNode()
        key.light = SCNLight()
        key.light!.type = .directional
        key.light!.intensity = 6
        key.light!.categoryBitMask = 1
        key.eulerAngles = SCNVector3(-0.4, 0.5, 0)
        scene.rootNode.addChildNode(key)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light!.type = .ambient
        ambient.light!.intensity = 2
        ambient.light!.categoryBitMask = 1
        scene.rootNode.addChildNode(ambient)

        let rim = SCNNode()
        rim.light = SCNLight()
        rim.light!.type = .directional
        rim.light!.intensity = 4
        rim.light!.categoryBitMask = 1
        rim.light!.color = NSColor(calibratedRed: 0.4, green: 0.9, blue: 0.82, alpha: 1)
        rim.eulerAngles = SCNVector3(0.3, .pi - 0.4, 0)
        scene.rootNode.addChildNode(rim)
    }

    // MARK: Avatar loading

    private func loadAvatar() {
        guard let scene else { return }
        loadGeneration &+= 1
        let generation = loadGeneration
        blinkTask?.cancel(); blinkTask = nil
        resetBlink()
        rootContainer.removeFromParentNode()
        rootContainer = SCNNode()
        morphNodes = []
        headNode = nil
        creatureEyes = []
        creaturePupils = []
        creatureJaw = nil
        creatureSmile = nil
        creatureMouthInterior = nil
        creatureTongue = nil
        creatureWings = []
        creatureCheeks = []
        creatureEyeBaseScale = SCNVector3(1, 1, 1)
        creatureFlame = nil
        dragonAura = nil
        creatureHead = nil
        creatureBaseHeadEuler = SCNVector3Zero
        usingCreature = false
        usingRuntimeDragon = false
        scene.rootNode.childNode(withName: "Room", recursively: false)?.isHidden = false
        scene.rootNode.addChildNode(rootContainer)

        if AvatarLocator.style == .creature {
            installCreature()
            return
        }

        if let avatarURL = AvatarLocator.effectiveAvatarURL {
            // GLTFKit2 invokes the handler on its own queue — must not
            // inherit this class's @MainActor isolation (runtime trap).
            GLTFAsset.load(with: avatarURL, options: [:]) { @Sendable [weak self] _, status, asset, error, _ in
                guard status == .complete || status == .error else { return }
                nonisolated(unsafe) let loadedAsset = asset
                Task { @MainActor [weak self] in
                    guard let self, self.view != nil, self.loadGeneration == generation else { return }
                    if status == .complete, let loadedAsset {
                        self.installGLTF(loadedAsset)
                    } else {
                        self.installPlaceholder()
                        _ = error
                    }
                }
            }
        } else {
            installPlaceholder()
        }
    }

    // MARK: Authored creature — an original multi-part GLB with named
    // expression controls for the eyes, jaw, wings, head and tail flame.

    private var dragonAura: SCNNode?
    private var creatureHead: SCNNode?           // head group — nods/tilts with state + voice
    private var creatureBaseHeadEuler = SCNVector3Zero

    // Scene accents match the authored model's ink/fire palette.
    private static let cBodyDeep      = NSColor(calibratedRed: 0.045, green: 0.06, blue: 0.11, alpha: 1)
    private static let cWing     = NSColor(calibratedRed: 0.98, green: 0.29, blue: 0.08, alpha: 1)   // flame orange
    private static let cCrest    = NSColor(calibratedRed: 0.72, green: 0.035, blue: 0.075, alpha: 1) // crimson

    private func skinMat(
        _ color: NSColor,
        shiny: Bool = false,
        roughness: CGFloat? = nil,
        metalness: CGFloat = 0
    ) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = color
        m.lightingModel = .physicallyBased
        m.roughness.contents = roughness ?? (shiny ? 0.20 : 0.46)
        m.metalness.contents = metalness
        m.clearCoat.contents = shiny ? 0.30 : 0.04
        m.clearCoatRoughness.contents = shiny ? 0.15 : 0.38
        m.locksAmbientWithDiffuse = false
        return m
    }
    private func installCreature() {
        usingCreature = true
        let generation = loadGeneration
        let runtimeURL = Bundle.main.url(forResource: "AitvarasDragonRuntime", withExtension: "glb")
        guard let modelURL = runtimeURL ?? Bundle.main.url(
            forResource: "AitvarasDragon", withExtension: "glb") else {
            usingCreature = false
            installPlaceholder()
            return
        }
        GLTFAsset.load(with: modelURL, options: [:]) { @Sendable [weak self] _, status, asset, _, _ in
            guard status == .complete || status == .error else { return }
            nonisolated(unsafe) let loadedAsset = asset
            Task { @MainActor [weak self] in
                guard let self, self.view != nil, self.loadGeneration == generation else { return }
                if status == .complete, let loadedAsset {
                    if runtimeURL != nil { self.installRuntimeDragon(loadedAsset) }
                    else { self.installDragonGLTF(loadedAsset) }
                } else {
                    self.usingCreature = false
                    self.installPlaceholder()
                }
            }
        }
    }

    /// Seated runtime copy: no authoring skeleton, IK, collision evaluation or
    /// locomotion clips. Live facial morphs retain the approved master detail.
    private func installRuntimeDragon(_ asset: GLTFAsset) {
        guard let scene, let imported = GLTFSCNSceneSource(asset: asset).defaultScene else {
            usingCreature = false
            installPlaceholder()
            return
        }
        usingRuntimeDragon = true
        scene.rootNode.childNode(withName: "Room", recursively: false)?.isHidden = true
        timeOfDayTask?.cancel(); timeOfDayTask = nil
        let dragon = SCNNode()
        dragon.name = "RuntimeDragon"
        for child in imported.rootNode.childNodes { dragon.addChildNode(child) }
        dragon.enumerateHierarchy { node, _ in
            node.categoryBitMask = 2
            node.castsShadow = false
            if node.morpher != nil { morphNodes.append(node) }
        }
        rootContainer.addChildNode(dragon)
        let bounds = dragon.boundingBox
        let center = SCNVector3((bounds.min.x + bounds.max.x) / 2,
                               (bounds.min.y + bounds.max.y) / 2,
                               (bounds.min.z + bounds.max.z) / 2)
        let height = max(bounds.max.y - bounds.min.y, 0.1)
        let width = max(bounds.max.x - bounds.min.x, 0.1)
        let viewport = view?.bounds.size ?? NSSize(width: 272, height: 282)
        let aspect = viewport.width > 0 && viewport.height > 0 ? viewport.width / viewport.height : 272.0 / 282.0

        // One environment and two diffuse sources: no shadow-map pass,
        // screen-space AO, bloom, ray tracing or dynamic reflection probes.
        scene.lightingEnvironment.contents = Self.verticalGradientImage(
            top: NSColor(calibratedRed: 0.82, green: 0.87, blue: 1, alpha: 1),
            bottom: NSColor(calibratedRed: 0.22, green: 0.24, blue: 0.30, alpha: 1))
        scene.lightingEnvironment.intensity = 1.1
        for (position, intensity, color) in [
            (SCNVector3(-2, 3, 4), CGFloat(900), NSColor(calibratedRed: 1, green: 0.88, blue: 0.76, alpha: 1)),
            (SCNVector3(3, 1, 1), CGFloat(400), NSColor(calibratedRed: 0.65, green: 0.76, blue: 1, alpha: 1))
        ] {
            let node = SCNNode()
            node.light = SCNLight()
            node.light!.type = .directional
            node.light!.intensity = intensity
            node.light!.color = color
            node.light!.categoryBitMask = 2
            node.light!.castsShadow = false
            node.position = position
            node.look(at: center)
            rootContainer.addChildNode(node)
        }
        let contact = SCNNode(geometry: SCNPlane(width: CGFloat(width * 0.70), height: CGFloat(width * 0.26)))
        let mat = SCNMaterial()
        mat.lightingModel = .constant
        mat.diffuse.contents = Self.radialShadowImage()
        mat.isDoubleSided = true
        mat.writesToDepthBuffer = false
        contact.geometry?.materials = [mat]
        // Screen-facing soft contact instead of an expensive dynamic shadow.
        contact.position = SCNVector3(center.x, bounds.min.y + height * 0.035, bounds.min.z - 0.02)
        contact.opacity = 0.32
        rootContainer.addChildNode(contact)

        scene.rootNode.childNodes.filter { $0.camera != nil }.forEach { $0.removeFromParentNode() }
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera!.usesOrthographicProjection = true
        camera.camera!.orthographicScale = Double(max(height, width / aspect) * 0.53)
        camera.camera!.zNear = 0.01
        camera.camera!.zFar = 20
        camera.camera!.wantsHDR = true
        camera.camera!.exposureOffset = 0.1
        camera.position = SCNVector3(center.x, center.y, bounds.max.z + 4)
        camera.look(at: center)
        scene.rootNode.addChildNode(camera)
        view?.pointOfView = camera
        avatarDidInstall()
    }

    /// Installs the authored multi-part GLB. The model's named nodes are
    /// expression controls: no rig is required for the jaw, eyes, wings,
    /// head tilt or tail flame.
    private func installDragonGLTF(_ asset: GLTFAsset) {
        let source = GLTFSCNSceneSource(asset: asset)
        guard let modelScene = source.defaultScene else {
            usingCreature = false
            installPlaceholder()
            return
        }

        let dragon = SCNNode()
        dragon.name = "AuthoredDragon"
        for child in modelScene.rootNode.childNodes {
            dragon.addChildNode(child)
        }

        let env = ProcessInfo.processInfo.environment
        let size = env["AITVARAS_SIZE"].flatMap(Double.init).map { CGFloat($0) } ?? 1
        let modelScale = 0.44 * size
        dragon.scale = SCNVector3(modelScale, modelScale * 0.87, modelScale)
        dragon.position = SCNVector3(0, 1.19, 0)
        dragon.eulerAngles.y = env["AITVARAS_DRAGON_YAW"]
            .flatMap(Double.init).map { CGFloat($0) } ?? 0.18
        dragon.enumerateHierarchy { node, _ in
            node.categoryBitMask = 2
            node.castsShadow = true
        }
        rootContainer.addChildNode(dragon)

        creatureHead = dragon.childNode(withName: "DragonHead", recursively: true)
        creatureJaw = dragon.childNode(withName: "Jaw", recursively: true)
        creatureSmile = dragon.childNode(withName: "Smile", recursively: true)
        creatureMouthInterior = dragon.childNode(withName: "MouthInterior", recursively: true)
        creatureTongue = dragon.childNode(withName: "Tongue", recursively: true)
        creatureFlame = dragon.childNode(withName: "TailFlame", recursively: true)
        creatureEyes = ["Eye.L", "Eye.R"].compactMap {
            dragon.childNode(withName: $0, recursively: true)
        }
        creaturePupils = ["Iris.L", "Iris.R"].compactMap {
            dragon.childNode(withName: $0, recursively: true)
        }
        creatureCheeks = ["Cheek.L", "Cheek.R"].compactMap {
            dragon.childNode(withName: $0, recursively: true)
        }
        creatureWings = ["Wing.L", "Wing.R"].compactMap {
            dragon.childNode(withName: $0, recursively: true)
        }
        if let head = creatureHead {
            head.scale = SCNVector3(1.12, 1.12, 1.12)
            head.position.y -= 0.075
            head.position.z += 0.010
        }
        creatureMouthInterior?.opacity = 0.04
        creatureTongue?.opacity = 0

        installCreatureStage()
        avatarDidInstall()
    }

    /// Shared presentation layer for the authored model. The platform is a
    /// shadow receiver; the three-point setup exposes planes and scale relief
    /// without flooding the dark blue materials.
    private func installCreatureStage() {
        let stage = SCNNode(geometry: SCNCylinder(radius: 0.42, height: 0.030))
        stage.geometry!.firstMaterial = skinMat(
            Self.cBodyDeep, roughness: 0.24, metalness: 0.16)
        stage.position = SCNVector3(0, 1.175, 0)
        stage.categoryBitMask = 2
        stage.castsShadow = false
        rootContainer.addChildNode(stage)

        let stageRim = SCNNode(geometry: SCNTorus(ringRadius: 0.405, pipeRadius: 0.009))
        stageRim.geometry!.firstMaterial = skinMat(
            Self.cCrest, shiny: true, roughness: 0.18, metalness: 0.42)
        stageRim.position = SCNVector3(0, 1.192, 0)
        stageRim.categoryBitMask = 2
        stageRim.castsShadow = false
        rootContainer.addChildNode(stageRim)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light!.type = .ambient
        ambient.light!.intensity = 1
        ambient.light!.categoryBitMask = 2
        rootContainer.addChildNode(ambient)

        let key = SCNNode()
        key.light = SCNLight()
        key.light!.type = .spot
        key.light!.intensity = 13
        key.light!.color = NSColor(
            calibratedRed: 1, green: 0.88, blue: 0.76, alpha: 1)
        key.light!.categoryBitMask = 2
        key.light!.spotInnerAngle = 32
        key.light!.spotOuterAngle = 68
        key.light!.castsShadow = true
        key.light!.shadowMode = .deferred
        key.light!.shadowColor = NSColor.black.withAlphaComponent(0.58)
        key.light!.shadowRadius = 7
        key.light!.shadowBias = 0.008
        key.light!.shadowMapSize = CGSize(width: 2048, height: 2048)
        key.light!.zNear = 0.08
        key.light!.zFar = 5
        key.position = SCNVector3(-0.72, 2.25, 1.20)
        key.look(at: SCNVector3(0, 1.43, 0))
        rootContainer.addChildNode(key)

        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light!.type = .directional
        fill.light!.intensity = 3
        fill.light!.color = NSColor(
            calibratedRed: 0.54, green: 0.68, blue: 1, alpha: 1)
        fill.light!.categoryBitMask = 2
        fill.eulerAngles = SCNVector3(-0.1, -0.7, 0)
        rootContainer.addChildNode(fill)

        let rim = SCNNode()
        rim.light = SCNLight()
        rim.light!.type = .directional
        rim.light!.intensity = 5
        rim.light!.color = Self.cWing
        rim.light!.categoryBitMask = 2
        rim.eulerAngles = SCNVector3(0.25, .pi - 0.55, 0)
        rootContainer.addChildNode(rim)

        scene?.lightingEnvironment.contents = Self.verticalGradientImage(
            top: NSColor(calibratedRed: 0.95, green: 0.97, blue: 1, alpha: 1),
            bottom: NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.18, alpha: 1))
        scene?.lightingEnvironment.intensity = 0.025

        let aura = SCNNode(geometry: SCNPlane(width: 0.62, height: 0.42))
        let auraMaterial = SCNMaterial()
        auraMaterial.lightingModel = .constant
        auraMaterial.diffuse.contents = Self.radialGlowImage(Self.cWing)
        auraMaterial.blendMode = .add
        auraMaterial.isDoubleSided = true
        auraMaterial.writesToDepthBuffer = false
        aura.geometry!.materials = [auraMaterial]
        aura.eulerAngles.x = -.pi / 2
        aura.position = SCNVector3(0, 1.193, 0)
        aura.renderingOrder = 10
        aura.opacity = 0.26
        rootContainer.addChildNode(aura)
        dragonAura = aura

        let contact = SCNNode(geometry: SCNPlane(width: 0.5, height: 0.34))
        let contactMaterial = SCNMaterial()
        contactMaterial.lightingModel = .constant
        contactMaterial.diffuse.contents = Self.radialShadowImage()
        contactMaterial.isDoubleSided = true
        contactMaterial.blendMode = .alpha
        contact.geometry!.materials = [contactMaterial]
        contact.eulerAngles.x = -.pi / 2
        contact.position = SCNVector3(0, 1.194, 0)
        contact.opacity = 0.42
        rootContainer.addChildNode(contact)

        frameCameraOnCreature()
        applyCreatureState(.idle)
    }

    private func frameCameraOnCreature() {
        guard let scene else { return }
        scene.rootNode.childNodes.filter { $0.camera != nil }.forEach { $0.removeFromParentNode() }
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera!.fieldOfView = 32
        cameraNode.camera!.zNear = 0.01
        cameraNode.camera!.zFar = 50
        cameraNode.camera!.wantsHDR = true
        cameraNode.camera!.exposureOffset = -0.20
        cameraNode.camera!.bloomIntensity = 0.035
        cameraNode.camera!.bloomThreshold = 1.05
        cameraNode.camera!.bloomBlurRadius = 6
        cameraNode.camera!.vignettingIntensity = 0.10
        cameraNode.camera!.vignettingPower = 0.8
        cameraNode.camera!.screenSpaceAmbientOcclusionIntensity = 0.62
        cameraNode.camera!.screenSpaceAmbientOcclusionRadius = 3
        cameraNode.camera!.screenSpaceAmbientOcclusionBias = 0.02
        cameraNode.position = SCNVector3(0, 1.55, 1.72)
        cameraNode.look(at: SCNVector3(0, 1.47, 0))
        scene.rootNode.addChildNode(cameraNode)
        // The view may have already rendered once and locked onto a
        // default POV before this camera existed.
        view?.pointOfView = cameraNode
    }

    /// The cartoon dragon's expression: eye shape, a curious head-tilt,
    /// cheek blush and the floor aura shift per state. The ink/fire body
    /// palette stays stable while mood reads through the face and glow.
    private func applyCreatureState(_ state: CharacterState, animated: Bool = true) {
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
        SCNTransaction.animationDuration = animated && visibility.canRender ? 0.3 : 0
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
        avatarDidInstall()
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
        avatarDidInstall()
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

    /// All installers finish here, including asynchronous loads that complete
    /// while hidden. Imported idle clips must not silently keep SceneKit busy.
    private func avatarDidInstall() {
        rootContainer.enumerateHierarchy { node, _ in
            node.removeAllActions()
            node.removeAllAnimations()
        }
        if visibility.canRender {
            transition(to: currentState)
            updateMouth(latestMouth)
            startBlinking()
            startTimeOfDayUpdates()
            requestRenderBurst(seconds: 0.65)
            view?.needsDisplay = true
        }
        updateRenderScheduling()
    }

    // MARK: Animation state

    func apply(state: CharacterState, mouth: Float) {
        let stateChanged = state != currentState
        let effectiveMouth: Float = state == .speaking ? min(max(mouth, 0), 1) : 0
        let mouthChanged = abs(effectiveMouth - latestMouth) > 0.0001
        latestMouth = effectiveMouth
        currentState = state
        // Model changes may continue while hidden; retain just the newest pose
        // inputs without touching SceneKit or waking any visual task.
        guard visibility.canRender else { return }
        guard stateChanged || mouthChanged else { return }
        if stateChanged {
            transition(to: state)
            requestRenderBurst(seconds: 0.65)
        }
        updateMouth(effectiveMouth)
        updateRenderScheduling()
    }

    private func updateMouth(_ mouth: Float) {
        smoothedMouth += (mouth - smoothedMouth) * 0.35
        if currentState != .speaking { smoothedMouth = 0 }
        if usingRuntimeDragon {
            setMorph("jawOpen", weight: CGFloat(min(smoothedMouth * 0.72, 0.6)), duration: 0.045)
            return
        }
        if usingCreature {
            // Her voice opens the jaw (real mouth movement), hides the
            // closed-mouth smile, pulses the floor aura, and — while
            // speaking — adds a gentle nod on top of the state pose.
            let m = CGFloat(min(smoothedMouth, 1))
            creatureJaw?.eulerAngles.x = m * 0.5
            creatureSmile?.opacity = 1 - min(m * 2.4, 1)
            creatureMouthInterior?.opacity = 0.04 + min(m * 3.2, 0.96)
            creatureTongue?.opacity = min(m * 3.0, 1)
            dragonAura?.opacity = 0.26 + m * 0.36
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

    private func transition(to state: CharacterState, animated: Bool = true) {
        currentState = state
        if usingRuntimeDragon {
            let duration = animated ? 0.2 : 0
            setMorph("eyeLookUp", weight: state == .thinking ? 0.45 : 0, duration: duration)
            setMorph("eyeLookLeft", weight: state == .thinking ? 0.25 : 0, duration: duration)
            setMorph("eyeLookRight", weight: 0, duration: duration)
            setMorph("eyeLookDown", weight: 0, duration: duration)
            return
        }
        if usingCreature { applyCreatureState(state, animated: animated) }
        guard let headNode else { return }
        headNode.removeAction(forKey: "stateMotion")
        switch state {
        case .idle:
            SCNTransaction.begin(); SCNTransaction.animationDuration = animated ? 0.6 : 0
            headNode.eulerAngles = SCNVector3(0, 0, 0)
            SCNTransaction.commit()
        case .listening:
            // Attentive: slight head tilt toward the user.
            SCNTransaction.begin(); SCNTransaction.animationDuration = animated ? 0.5 : 0
            headNode.eulerAngles = SCNVector3(0.06, 0, 0.05)
            SCNTransaction.commit()
        case .thinking:
            guard animated, visibility.canRender else {
                headNode.eulerAngles = SCNVector3(0.04, 0.12, 0)
                return
            }
            // Pensive slow sway.
            let left = SCNAction.rotateTo(x: 0.04, y: 0.12, z: 0, duration: 1.6)
            left.timingMode = .easeInEaseOut
            let right = SCNAction.rotateTo(x: 0.04, y: -0.12, z: 0, duration: 1.6)
            right.timingMode = .easeInEaseOut
            headNode.runAction(.repeatForever(.sequence([left, right])), forKey: "stateMotion")
        case .speaking:
            SCNTransaction.begin(); SCNTransaction.animationDuration = animated ? 0.4 : 0
            headNode.eulerAngles = SCNVector3(0.02, 0, 0)
            SCNTransaction.commit()
        }
    }

    private func startBlinking() {
        blinkTask?.cancel()
        guard visibility.canRender else { blinkTask = nil; return }
        blinkTask = Task { [weak self] in
            while !Task.isCancelled {
                let pause = Double.random(in: 4.0...8.0)
                do { try await Task.sleep(for: .seconds(pause)) }
                catch { return }
                guard !Task.isCancelled, self?.visibility.canRender == true else { return }
                await self?.blink()
            }
        }
    }

    private func blink() async {
        guard visibility.canRender, !Task.isCancelled else { return }
        guard !usingCreature || currentState != .thinking else { return }
        guard usingCreature && !usingRuntimeDragon ? !creatureEyes.isEmpty : !morphNodes.isEmpty else { return }
        let generation = loadGeneration
        requestRenderBurst(seconds: 0.28)
        if usingCreature && !usingRuntimeDragon {
            // Squash the big eyes shut, then restore the state's shape.
            SCNTransaction.begin(); SCNTransaction.animationDuration = 0.07
            for eye in creatureEyes {
                eye.scale = SCNVector3(creatureEyeBaseScale.x, creatureEyeBaseScale.y * 0.08, creatureEyeBaseScale.z)
            }
            SCNTransaction.commit()
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return }
            guard !Task.isCancelled, visibility.canRender, generation == loadGeneration else { return }
            SCNTransaction.begin(); SCNTransaction.animationDuration = 0.12
            for eye in creatureEyes { eye.scale = creatureEyeBaseScale }
            SCNTransaction.commit()
            return
        }
        setMorph("eyeBlinkLeft", weight: 1, duration: 0.07)
        setMorph("eyeBlinkRight", weight: 1, duration: 0.07)
        do { try await Task.sleep(for: .milliseconds(110)) }
        catch { return }
        guard !Task.isCancelled, visibility.canRender, generation == loadGeneration else { return }
        setMorph("eyeBlinkLeft", weight: 0, duration: 0.12)
        setMorph("eyeBlinkRight", weight: 0, duration: 0.12)
    }

    private func resetBlink() {
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        for eye in creatureEyes { eye.scale = creatureEyeBaseScale }
        for node in morphNodes {
            node.morpher?.setWeight(0, forTargetNamed: "eyeBlinkLeft")
            node.morpher?.setWeight(0, forTargetNamed: "eyeBlinkRight")
        }
        SCNTransaction.commit()
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
