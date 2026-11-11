import AppKit
import Metal
import QuartzCore

/// Two Metal layers and a display link that asks for only as many frames as
/// the scene needs right now.
///
/// - The sky layer redraws every frame, at one pixel per point.
/// - The ridge layer sits on top at full Retina resolution and redraws only
///   when the light has shifted or the pointer moves it.
/// - Frame rate: one a second when nothing in the sky moves but the sun, ten
///   while you work in another app, twenty when the desktop is in front, more
///   while the ridges are moving, and full speed only for the second a
///   shooting star takes to cross.
final class SceneView: NSView {
    private let kind: SceneKind
    private let skyLayer = CAMetalLayer()
    private let ridgeLayer = CAMetalLayer()
    private var link: CADisplayLink?
    private var soft: MTLTexture?
    private var skyPass = PassInfo(), ridgePass = PassInfo()

    /// Animation time handed from one view to its replacement, so rebuilding
    /// the windows (a monitor plugged in, say) does not restart the clouds.
    private static var carriedElapsed = 0.0
    private var elapsed = SceneView.carriedElapsed
    private var last = CACurrentMediaTime()
    private var lastFrame = 0.0
    private var needsFrame = true

    private var parallax: Float = 0
    private var ridgeParallax: Float = 0
    private var ridgeTime = 0.0
    private var ridgeElevation: Float = 0
    private var ridgeStale = true
    private var softTime = -1.0
    private var builtFor: (saving: Bool, seed: UInt64) = (false, 0)

    /// Frames a second currently asked for.
    private(set) var fps: Float = 0

    private var frameCount = 0
    private var ridgeCount = 0
    private var statsTime = CACurrentMediaTime()
    private var cpuNanos: UInt64 = 0
    private static let logStats = ProcessInfo.processInfo.environment["LW_STATS"] != nil

    private struct Meteor { var start: V2, direction: V2, travel: Float, begin: Double, duration: Double }
    private var meteor: Meteor?
    private var nextMeteor = SceneView.carriedElapsed + 6

    var playing = false {
        didSet {
            guard playing != oldValue else { return }
            last = CACurrentMediaTime()
            needsFrame = true
            link?.isPaused = !playing
        }
    }

    init(frame: NSRect, kind: SceneKind) {
        self.kind = kind
        super.init(frame: frame)
        let host = CALayer()
        host.backgroundColor = .black
        layer = host                    // layer-hosting: we own the sublayers
        wantsLayer = true
        for (metal, opaque) in [(skyLayer, true), (ridgeLayer, false)] {
            metal.device = Renderer.shared?.device
            metal.pixelFormat = .bgra8Unorm
            metal.framebufferOnly = true
            metal.isOpaque = opaque
            metal.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            metal.maximumDrawableCount = 2
            metal.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull(), "hidden": NSNull()]
            host.addSublayer(metal)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, link == nil else { return }
        layoutLayers()
        let l = displayLink(target: self, selector: #selector(tick))
        l.isPaused = !playing
        l.add(to: .main, forMode: .common)
        link = l
        drawNow()       // a window always shows a picture, even if it starts paused or hidden
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layoutLayers()
        drawNow()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutLayers()
    }

    func stop() {
        SceneView.carriedElapsed = elapsed
        link?.invalidate()
        link = nil
    }

    /// A shooting star shortly after the Mac wakes, if it is night.
    func greet() { nextMeteor = min(nextMeteor, elapsed + 1.5) }

    /// Draws one frame immediately, whether or not the animation is running.
    /// Used when a setting changes while paused, and for a window's first frame.
    func drawNow() {
        guard window != nil else { return }
        needsFrame = true
        ridgeStale = true
        renderFrame(now: CACurrentMediaTime())
    }

    private func layoutLayers() {
        let model = SceneModel.shared
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let backing = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        builtFor = (Conditions.shared.saving, model.seed)
        let layout = SceneLayout(size: size, kind: kind, terrain: model.terrain)
        let sharp = builtFor.saving ? 1 : backing       // ridges at plain points when saving power

        skyLayer.frame = CGRect(x: 0, y: layout.skyBottom, width: size.width, height: size.height - layout.skyBottom)
        skyLayer.drawableSize = skyLayer.frame.size
        skyPass = PassInfo(r: V4(Float(layout.skyBottom / size.height), 1, Float(size.height), 1))

        ridgeLayer.isHidden = kind != .horizon
        if kind == .horizon {
            ridgeLayer.frame = CGRect(x: 0, y: 0, width: size.width, height: layout.ridgeTop)
            ridgeLayer.drawableSize = CGSize(width: (size.width * sharp).rounded(),
                                             height: (layout.ridgeTop * sharp).rounded())
            ridgePass = PassInfo(r: V4(0, Float(layout.ridgeTop / size.height), Float(size.height * sharp), Float(sharp)))
        }
        soft = nil
        ridgeStale = true
        needsFrame = true
    }

    @objc private func tick(_ sender: CADisplayLink) {
        // The system treats the requested rate as a preference, and on some
        // displays rounds it up. Hold to it here so the cost never depends on that.
        let now = CACurrentMediaTime()
        if !needsFrame, fps > 0, now - lastFrame < 0.85 / Double(fps) { return }
        renderFrame(now: now)
    }

    private func renderFrame(now: CFTimeInterval) {
        guard let renderer = Renderer.shared, bounds.width > 0, bounds.height > 0 else { return }
        let cpuStart = SceneView.logStats ? clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) : 0
        // Long gaps are clamped so a wake from sleep does not lurch the scene,
        // but the clamp has to allow the gap a slow frame rate produces by design.
        let dt = playing ? min(now - last, max(0.25, 2 / Double(max(fps, 1)))) : 0
        last = now
        elapsed += dt

        let conditions = Conditions.shared
        let model = SceneModel.shared
        if conditions.saving != builtFor.saving || model.seed != builtFor.seed { layoutLayers() }
        let horizon = kind == .horizon
        let lapse = horizon && model.skyMode == .lapse

        // The ridges lean a little toward the pointer, nearer ones more, but
        // only while the desktop is what you are looking at.
        var target: Float = 0
        if horizon, model.parallax, conditions.desktopInFront, !conditions.saving, let screen = window?.screen {
            let mouse = NSEvent.mouseLocation
            if screen.frame.contains(mouse) { target = Float((mouse.x - screen.frame.midX) / screen.frame.width) }
        }
        parallax += (target - parallax) * Float(1 - exp(-dt * 2.5))
        if abs(target - parallax) < 0.0008 { parallax = target }       // settle, rather than creep forever
        let moving = parallax != target

        let aspect = Float(bounds.width / bounds.height)
        var (u, info) = model.uniforms(FrameInput(date: model.sceneDate(), elapsed: elapsed,
                                                  aspect: aspect, parallax: parallax))
        if horizon { updateMeteor(&u, stars: info.stars, aspect: aspect, saving: conditions.saving) }

        let want: Float
        if conditions.saving {
            want = horizon && info.skyIsStill ? 1 : 5
        } else if meteor != nil {
            want = conditions.onBattery || !conditions.desktopInFront ? 30 : 60
        } else if moving || lapse {
            want = 30
        } else if horizon, info.skyIsStill {
            // Only the sun is moving. Stay responsive to the pointer if it can move the ridges.
            want = conditions.desktopInFront && model.parallax ? 10 : 1
        } else if horizon, info.stars <= 0.003 {
            want = conditions.onBattery && !conditions.desktopInFront ? 6 : 10     // clouds repaint at most ten times a second
        } else if conditions.desktopInFront {
            want = conditions.onBattery ? 15 : 20
        } else {
            want = conditions.onBattery ? 6 : 10
        }
        if want != fps {
            fps = want
            link?.preferredFrameRateRange = CAFrameRateRange(minimum: want, maximum: want, preferred: want)
        }

        // Clouds, aurora and glow drift slowly, so the soft sky is repainted at
        // most ten times a second however fast frames are going out.
        var refreshSoft = lapse || needsFrame || elapsed - softTime >= 0.095
        if soft == nil {
            soft = renderer.makeSoftTarget(pointSize: skyLayer.frame.size)
            refreshSoft = true
        }
        guard let soft, let buffer = renderer.makeBuffer(), let sky = skyLayer.nextDrawable() else { return }
        if refreshSoft { softTime = elapsed }
        renderer.encodeSky(buffer, target: sky.texture, soft: soft, refreshSoft: refreshSoft,
                           uniforms: &u, kind: kind, pass: skyPass)

        // The ridges change only as fast as the light does: redraw when the
        // pointer has moved them a quarter of a pixel, when the sun has moved a
        // fiftieth of a degree through the range where colours change, or
        // every ten seconds for the mist.
        var ridge: CAMetalDrawable?
        if horizon {
            let shiftPixels = abs(parallax - ridgeParallax) * 0.031 * ridgePass.r.z
            let paletteMoving = info.sunElevation > -19 && info.sunElevation < 26
            if ridgeStale || lapse || shiftPixels > 0.25 || (!moving && parallax != ridgeParallax)
                || (paletteMoving && abs(info.sunElevation - ridgeElevation) > 0.02) || elapsed - ridgeTime > 10 {
                ridge = ridgeLayer.nextDrawable()
                if let ridge {
                    renderer.encodeRidges(buffer, target: ridge.texture, uniforms: &u, pass: ridgePass)
                    ridgeStale = false
                    ridgeParallax = parallax
                    ridgeElevation = info.sunElevation
                    ridgeTime = elapsed
                    ridgeCount += 1
                }
            }
        }

        frameCount += 1
        if frameCount % 16 == 0 || ridge != nil {
            let withRidge = ridge != nil
            buffer.addCompletedHandler { b in
                let ms = (b.gpuEndTime - b.gpuStartTime) * 1000
                DispatchQueue.main.async {
                    if withRidge { Renderer.ridgeMillis = ms } else { Renderer.skyMillis = ms }
                }
            }
        }
        buffer.present(sky)
        if let ridge { buffer.present(ridge) }
        buffer.commit()

        lastFrame = now
        needsFrame = false

        if SceneView.logStats {                 // testing aid: LW_STATS=1
            cpuNanos += clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart
            if frameCount % 40 == 0 {
                print(String(format: "cpu %.3f ms/frame | %2.0f fps asked, %4.1f delivered | sky %.3f ms (%dx%d) | ridges %.3f ms (%dx%d), %d redraws in %d frames | desktop in front: %@",
                             Double(cpuNanos) / 40 / 1e6, fps, 40 / max(now - statsTime, 0.001), Renderer.skyMillis,
                             Int(skyLayer.drawableSize.width), Int(skyLayer.drawableSize.height), Renderer.ridgeMillis,
                             Int(ridgeLayer.drawableSize.width), Int(ridgeLayer.drawableSize.height),
                             ridgeCount, frameCount, conditions.desktopInFront ? "yes" : "no"))
                fflush(stdout)
                statsTime = now
                cpuNanos = 0
            }
        }
    }

    private func updateMeteor(_ u: inout Uniforms, stars: Float, aspect: Float, saving: Bool) {
        if meteor == nil, elapsed >= nextMeteor {
            if stars > 0.5, !saving, playing {
                let x = Float.random(in: -0.42...0.42) * aspect
                let angle = Float.random(in: 0.30...0.70)
                let side: Float = x > 0 ? -1 : 1
                meteor = Meteor(start: V2(x, Float.random(in: 0.62...0.97)),
                                direction: V2(side * cos(angle), -sin(angle)),
                                travel: Float.random(in: 0.30...0.55),
                                begin: elapsed, duration: Double.random(in: 0.6...1.0))
            } else {
                nextMeteor = elapsed + 30
            }
        }
        guard let m = meteor else { return }
        let p = Float((elapsed - m.begin) / m.duration)
        if p >= 1 {
            meteor = nil
            nextMeteor = elapsed + Double.random(in: 25...80)
            return
        }
        let head = m.start + m.direction * (m.travel * p)
        let tail = head - m.direction * (0.16 * sin(.pi * p))
        u.meteorA = V4(head.x, head.y, tail.x, tail.y)
        u.meteorB = V4(pow(sin(.pi * p), 0.7), 0, 0, 0)
    }
}
