import AppKit
import Metal
import QuartzCore

/// What a wallpaper window needs from whatever is drawing in it.
protocol SceneHost: AnyObject {
    var playing: Bool { get set }
    var fps: Float { get }
    func drawNow()
    func stop()
    func greet()
}

extension SceneView: SceneHost {}

/// Shows a shader scene: draws it into a small off-screen target at the
/// scene's own resolution, then scales that onto the screen with dither.
///
/// Imported shaders are not written with energy in mind, so this view is
/// their governor: it caps the frame rate, and if a scene costs more GPU time
/// than a wallpaper should it lowers the resolution, then the frame rate.
final class ShaderSceneView: NSView, SceneHost {
    private let scene: ShaderScene
    private let metal = CAMetalLayer()
    private var link: CADisplayLink?
    private var target: MTLTexture?

    /// Animation time handed from a view to its replacement, per scene.
    private static var carried: [String: Double] = [:]
    private var elapsed: Double
    private var last = CACurrentMediaTime()
    private var lastFrame = 0.0
    private var needsFrame = true
    private var frameCount = 0

    private var pixelsPerPoint: CGFloat         // lowered by the governor if the scene is too heavy
    private var overBudget = 0, underBudget = 0
    private var fullRate: Float = 0             // the rate asked for before any throttling
    private var failedFrames = 0
    private var throttled = false               // resolution is at its floor and the scene is still heavy
    private var gpuMillis = 0.0
    private(set) var fps: Float = 0

    /// Called once, on the main thread, when the shader cannot be compiled.
    var onFailure: ((String) -> Void)?
    /// Called once, after the first frame has really been drawn by the GPU.
    var onFirstFrame: (() -> Void)?
    private var confirmedFirstFrame = false     // the GPU has finished one frame without error
    private static let logStats = ProcessInfo.processInfo.environment["LW_STATS"] != nil

    var playing = false {
        didSet {
            guard playing != oldValue else { return }
            // Coming back from hidden: the one moment a jump in time cannot be seen.
            if playing { elapsed = ShaderScene.fold(elapsed, limit: ShaderScene.timeRest) }
            last = CACurrentMediaTime()
            needsFrame = true
            link?.isPaused = !playing
        }
    }

    init(frame: NSRect, scene: ShaderScene) {
        self.scene = scene
        elapsed = ShaderScene.fold(ShaderSceneView.carried[scene.descriptor.id] ?? 0, limit: ShaderScene.timeRest)
        pixelsPerPoint = CGFloat(scene.descriptor.scale)
        super.init(frame: frame)
        wantsLayer = true
        metal.device = Renderer.shared?.device
        metal.pixelFormat = .bgra8Unorm
        metal.framebufferOnly = true
        metal.isOpaque = true
        metal.backgroundColor = .black
        metal.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metal.maximumDrawableCount = 2
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func makeBackingLayer() -> CALayer { metal }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, link == nil, let renderer = Renderer.shared else { return }
        let l = displayLink(target: self, selector: #selector(tick))
        l.isPaused = !playing
        l.add(to: .main, forMode: .common)
        link = l
        scene.compile(renderer) { [weak self] ok in
            guard let self else { return }
            if ok { self.drawNow() } else { self.onFailure?(self.scene.failure ?? "The shader could not be compiled.") }
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        target = nil
        drawNow()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        target = nil
        needsFrame = true
    }

    func stop() {
        ShaderSceneView.carried[scene.descriptor.id] = elapsed
        link?.invalidate()
        link = nil
    }

    func greet() {}

    func drawNow() {
        guard window != nil else { return }
        needsFrame = true
        renderFrame(now: CACurrentMediaTime())
    }

    @objc private func tick(_ sender: CADisplayLink) {
        let now = CACurrentMediaTime()
        if !needsFrame, fps > 0, now - lastFrame < 0.85 / Double(fps) { return }
        renderFrame(now: now)
    }

    private func renderFrame(now: CFTimeInterval) {
        guard let renderer = Renderer.shared, scene.pipeline != nil, bounds.width > 0, bounds.height > 0 else { return }
        let delta = playing ? min(now - last, max(0.25, 2 / Double(max(fps, 1)))) : 0
        last = now
        elapsed = ShaderScene.fold(elapsed + delta, limit: ShaderScene.timeLimit)   // a visible cut, once an hour, only if never hidden

        let conditions = Conditions.shared
        fullRate = FramePolicy.sceneRate(conditions.framePolicy, maxFPS: scene.descriptor.maxFPS)
        let want = throttled ? min(fullRate, 5) : fullRate
        if want != fps {
            fps = want
            link?.preferredFrameRateRange = CAFrameRateRange(minimum: want, maximum: want, preferred: want)
        }

        // The screen layer is one pixel per point unless the scene asks for more;
        // the scene itself is drawn at its own, usually lower, resolution.
        let backing = window?.backingScaleFactor ?? 2
        let layerScale: CGFloat = scene.descriptor.scale > 1 ? backing : 1
        let layerSize = CGSize(width: (bounds.width * layerScale).rounded(), height: (bounds.height * layerScale).rounded())
        if metal.drawableSize != layerSize { metal.drawableSize = layerSize }
        let drawScale = min(pixelsPerPoint, backing) * (conditions.saving ? 0.5 : 1)
        let size = CGSize(width: max(16, (bounds.width * drawScale).rounded()),
                          height: max(16, (bounds.height * drawScale).rounded()))
        if target == nil || target?.width != Int(size.width) || target?.height != Int(size.height) {
            target = renderer.makeTarget(width: Int(size.width), height: Int(size.height), format: ShaderScene.targetFormat)
        }
        guard let target, let buffer = renderer.makeBuffer(), let drawable = metal.nextDrawable() else { return }

        var u = ShaderScene.uniforms(pixels: size, pixelsPerPoint: drawScale, elapsed: elapsed, delta: delta,
                                     frame: frameCount, cap: fps, date: Date(), place: SceneModel.shared.place)
        scene.encode(buffer, target: target, uniforms: &u)
        renderer.encodePresent(buffer, source: target, target: drawable.texture)

        frameCount += 1
        // Every frame is watched until one has succeeded, then every eighth.
        if !confirmedFirstFrame || frameCount % 8 == 0 {
            buffer.addCompletedHandler { [weak self] b in
                let ms = (b.gpuEndTime - b.gpuStartTime) * 1000
                let failed = b.status == .error
                DispatchQueue.main.async { self?.frameFinished(gpuMillis: ms, failed: failed) }
            }
        }
        buffer.present(drawable)
        buffer.commit()
        lastFrame = now
        needsFrame = false

        if ShaderSceneView.logStats, frameCount % 40 == 0 {      // testing aid: LW_STATS=1
            print(String(format: "%@ | %2.0f fps asked | %.2f ms gpu | %.0fx%.0f at %.2f px/pt%@",
                         scene.descriptor.id, fps, gpuMillis, size.width, size.height, drawScale,
                         throttled ? " | throttled" : ""))
            fflush(stdout)
        }
    }

    /// The governor. GPU milliseconds per second is the cost that matters; a
    /// scene that stays over budget loses resolution first, then frame rate.
    private func frameFinished(gpuMillis ms: Double, failed: Bool) {
        if failed {
            // One rejected frame proves little (the GPU refuses work from a
            // session that is switched out, for one); three in a row while
            // really playing means this scene cannot be drawn here.
            guard playing else { return }
            failedFrames += 1
            if failedFrames >= 3 {
                onFailure?("The graphics driver rejected this scene's frames.")
                onFailure = nil
            } else {
                needsFrame = true
            }
            return
        }
        failedFrames = 0
        if !confirmedFirstFrame {
            // The first frame includes one-off set-up, so it says nothing about the scene's cost.
            confirmedFirstFrame = true
            onFirstFrame?()
            onFirstFrame = nil
            return
        }
        gpuMillis = ms
        guard playing else { overBudget = 0; underBudget = 0; return }
        let budget: Double = Conditions.shared.onBattery ? 60 : 120
        if ms * Double(fps) > budget {
            underBudget = 0
            overBudget += 1
            guard overBudget >= 3 else { return }
            overBudget = 0
            if pixelsPerPoint > 0.26 {
                pixelsPerPoint = max(0.25, pixelsPerPoint * 0.75)
                target = nil
            } else {
                throttled = true
            }
            return
        }
        overBudget = 0
        // The way back up. A step up in resolution costs about 1.8 times as
        // much, and lifting the throttle multiplies the frame rate, so climb
        // only when what the scene would cost afterwards is under half the
        // budget, and only after it has stayed that way for a while (a brief
        // squeeze from another app must not leave the wallpaper degraded for good).
        let scale = CGFloat(scene.descriptor.scale)
        let after = throttled ? ms * Double(fullRate) : ms * Double(fps) / (0.75 * 0.75)
        guard throttled || pixelsPerPoint < scale, after < budget / 2 else { underBudget = 0; return }
        underBudget += 1
        guard underBudget >= 12 else { return }
        underBudget = 0
        if throttled {
            throttled = false
        } else {
            pixelsPerPoint = min(scale, pixelsPerPoint / 0.75)
            target = nil
        }
    }
}
