import AppKit
import Metal
import ImageIO
import UniformTypeIdentifiers

// MARK: - Headless rendering (for checking the picture and timing the GPU)

/// `LiveWallpaper --render out.png [--size 4112x2658] [--scale 2] [--date "2026-06-21 19:40"]
///  [--hour 18.5] [--sky dusk] [--scene nebula] [--seed 7] [--t 40] [--cloud 0.4] [--aurora 1]
///  [--meteor 1] [--parallax 0.3] [--bench 200]`
///
/// `--size` is in pixels and `--scale` is pixels per point, as on a Retina display.
enum Headless {
    static func run(_ args: [String]) -> Never {
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        func fail(_ message: String) -> Never {
            FileHandle.standardError.write(Data((message + "\n").utf8))
            exit(2)
        }
        let known: Set<String> = ["--help", "--render", "--bench", "--scene-dir", "--check-scenes", "--list-scenes", "--previews", "--size", "--scale", "--date", "--hour", "--sky", "--scene",
                                  "--seed", "--t", "--cloud", "--aurora", "--meteor", "--parallax", "--lat", "--lon"]
        let unknown = args.dropFirst().filter { $0.hasPrefix("--") && !known.contains($0) }
        if !unknown.isEmpty || args.contains("--help") {
            let usage = """
            Draws frames off screen; no window is opened.
              --render FILE.png        write one frame
              --bench N                time N frames under sustained load (GPU ms per frame)
              --size WxH  --scale S    output pixels and pixels per point (default 4112x2658, 2)
              --hour H | --date "yyyy-MM-dd HH:mm" | --sky dawn|day|golden|dusk|night
              --lat DEG --lon DEG      place on Earth (default: from the time zone)
              --scene ID               any scene in the library (see --list-scenes); default horizon
              --scene-dir FOLDER       a scene folder that is not installed (for work in progress)
              --seed N   --t SECONDS   --cloud 0..1   --aurora 0..1   --meteor 0..1   --parallax -0.5..0.5
              --list-scenes            every scene with its author and licence
              --check-scenes [--previews DIR]   compile, draw and time every shader scene
            """
            if !unknown.isEmpty { FileHandle.standardError.write(Data("Unknown option: \(unknown.joined(separator: " "))\n".utf8)) }
            print(usage)
            exit(unknown.isEmpty ? 0 : 2)
        }
        if args.contains("--list-scenes") {
            for s in SceneRegistry.shared.scenes {
                print("\(s.id)\t\(s.style.rawValue)\t\(s.licence)\t\(s.credit)")
            }
            for p in SceneRegistry.shared.problems { FileHandle.standardError.write(Data((p + "\n").utf8)) }
            exit(0)
        }
        if args.contains("--check-scenes") {
            guard let renderer = Renderer.shared else { fail(Renderer.failure ?? "Metal is unavailable.") }
            HeadlessShader.checkAll(renderer: renderer, registry: SceneRegistry.shared, previews: value("--previews"),
                                    place: Location.place(for: .autoupdatingCurrent))
        }
        guard args.contains("--render") || args.contains("--bench") else {
            fail("Nothing to do: pass --render FILE.png or --bench N (or --help).")
        }
        if args.contains("--render"), value("--render").map({ $0.hasPrefix("--") }) ?? true {
            fail("--render needs a file name")
        }
        // Frames must not depend on what the installed app happens to have saved:
        // the default landscape and the time zone's city, unless told otherwise.
        let model = SceneModel.shared
        if args.contains("--lat") || args.contains("--lon") {
            guard let lat = value("--lat").flatMap({ Double($0) }), let lon = value("--lon").flatMap({ Double($0) }),
                  abs(lat) <= 90, abs(lon) <= 180 else { fail("--lat and --lon must both be given, in degrees") }
            model.overridePlace(Place(latitude: lat, longitude: lon, source: .manual))
        } else {
            model.overridePlace(Location.place(for: .autoupdatingCurrent))
        }
        if args.contains("--seed") {
            guard let s = value("--seed").flatMap({ UInt64($0) }) else { fail("--seed must be a whole number") }
            model.reseed(s)
        } else {
            model.reseed(SceneModel.defaultSeed)
        }
        guard let renderer = Renderer.shared else {
            FileHandle.standardError.write(Data("\(Renderer.failure ?? "Metal is unavailable.")\n".utf8))
            exit(1)
        }
        renderer.terrainChanged()

        let dims = (value("--size") ?? "4112x2658").split(separator: "x").compactMap { Int($0) }
        guard dims.count == 2, dims[0] > 0, dims[1] > 0, dims[0] <= 16384, dims[1] <= 16384 else {
            fail("--size must be WxH in pixels, for example 4112x2658")
        }
        let width = dims[0], height = dims[1]
        guard let scaleValue = Double(value("--scale") ?? "2"), scaleValue > 0, scaleValue <= 4 else {
            fail("--scale must be a number of pixels per point, such as 1 or 2")
        }
        let scale = CGFloat(scaleValue)
        var kind = SceneKind.horizon
        var shader: SceneDescriptor?
        if let dir = value("--scene-dir") {
            switch SceneRegistry.load(URL(fileURLWithPath: dir).standardizedFileURL) {
            case .success(let d): shader = d
            case .failure(let problem): fail("\(dir): \(problem.message)")
            }
        } else {
            let id = value("--scene") ?? "horizon"
            guard let d = SceneRegistry.shared.scene(id) else { fail("Unknown scene: \(id) (see --list-scenes)") }
            if case .builtin(let k) = d.source { kind = k } else { shader = d }
        }
        let t0 = Double(value("--t") ?? "40") ?? 40
        let parallax = Float(value("--parallax") ?? "0") ?? 0
        model.cloudOverride = value("--cloud").flatMap { Float($0) }
        model.auroraOverride = value("--aurora").flatMap { Float($0) }

        var date = Date()
        if let s = value("--date") {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm"
            guard let parsed = f.date(from: s) else { fail("--date must look like \"2026-06-21 19:40\"") }
            date = parsed
        } else if let h = value("--hour").flatMap({ Double($0) }) {
            date = Calendar.current.startOfDay(for: date).addingTimeInterval(h * 3600)
        } else if let name = value("--sky") {
            guard let mode = SkyMode(rawValue: name), mode != .real, mode != .lapse else {
                fail("--sky must be dawn, day, golden, dusk or night")
            }
            model.skyMode = mode
            date = model.sceneDate()
        }

        let frames = max(1, Int(value("--bench") ?? "1") ?? 1)
        if let shader {
            HeadlessShader.run(shader, renderer: renderer, width: width, height: height, scale: scale,
                               elapsed: t0, date: date, frames: frames, path: value("--render"), place: model.place)
        }

        // The same geometry the view uses.
        let points = CGSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        let layout = SceneLayout(size: points, kind: kind, terrain: model.terrain)
        let skySize = CGSize(width: points.width, height: points.height - layout.skyBottom)
        let ridgeSize = CGSize(width: (points.width * scale).rounded(), height: (layout.ridgeTop * scale).rounded())
        let skyPass = PassInfo(r: V4(Float(layout.skyBottom / points.height), 1, Float(points.height), 1))
        let ridgePass = PassInfo(r: V4(0, Float(layout.ridgeTop / points.height), Float(points.height * scale), Float(scale)))

        func target(_ size: CGSize) -> MTLTexture? {
            guard size.width >= 1, size.height >= 1 else { return nil }
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(size.width),
                                                             height: Int(size.height), mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            return renderer.device.makeTexture(descriptor: d)
        }
        guard let skyTarget = target(skySize), let soft = renderer.makeSoftTarget(pointSize: skySize)
        else { fatalError("could not create render targets") }
        let ridgeTarget = target(ridgeSize)

        func uniforms(_ i: Int) -> Uniforms {
            var (u, _) = model.uniforms(FrameInput(date: date, elapsed: t0 + Double(i) / 20,
                                                   aspect: Float(points.width / points.height), parallax: parallax))
            if let m = value("--meteor").flatMap({ Float($0) }) {
                u.meteorA = V4(0.25, 0.80, 0.25 - 0.14 * m, 0.80 + 0.08 * m)
                u.meteorB = V4(m, 0, 0, 0)
            }
            return u
        }
        // Frames are queued back to back and timed as a batch, so the GPU is
        // held at full clock speed and the figure reflects work, not how
        // sleepy the GPU was allowed to get between frames.
        func timed(_ frames: Int, _ encode: (MTLCommandBuffer, inout Uniforms) -> Void) -> Double {
            var buffers = [MTLCommandBuffer]()
            for i in 0..<frames {
                var u = uniforms(i)
                guard let buffer = renderer.makeBuffer() else { continue }
                encode(buffer, &u)
                buffer.commit()
                buffers.append(buffer)
            }
            buffers.last?.waitUntilCompleted()
            guard let first = buffers.first, let lastBuffer = buffers.last else { return 0 }
            let warm = buffers[min(buffers.count - 1, buffers.count / 4)]       // skip the ramp-up
            if frames < 8 { return (lastBuffer.gpuEndTime - first.gpuStartTime) * 1000 / Double(buffers.count) }
            return (lastBuffer.gpuEndTime - warm.gpuStartTime) * 1000 / Double(buffers.count - buffers.count / 4)
        }

        let skyMs = timed(frames) { renderer.encodeSky($0, target: skyTarget, soft: soft, uniforms: &$1, kind: kind, pass: skyPass) }
        var ridgeMs = 0.0
        if let ridgeTarget {
            ridgeMs = timed(frames) { renderer.encodeRidges($0, target: ridgeTarget, uniforms: &$1, pass: ridgePass) }
        }
        if frames > 1 {
            print(String(format: "every frame: %.3f ms (sky %d×%d) | ridge redraw: %.3f ms (%d×%d)",
                         skyMs, Int(skySize.width), Int(skySize.height), ridgeMs, Int(ridgeSize.width), Int(ridgeSize.height)))
        }

        if let path = value("--render") {
            // Put the two layers together the way the window server does:
            // the sky scaled up to the screen's pixels, the ridges laid over it.
            func image(_ texture: MTLTexture, alpha: CGImageAlphaInfo) -> CGImage? {
                guard let bytes = Snapshot.pixels(of: texture, renderer: renderer),
                      let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
                return CGImage(width: texture.width, height: texture.height, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: texture.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | alpha.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            }
            if let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
               let skyImage = image(skyTarget, alpha: .noneSkipFirst) {
                ctx.interpolationQuality = .low
                ctx.draw(skyImage, in: CGRect(x: 0, y: layout.skyBottom * scale, width: CGFloat(width),
                                              height: skySize.height * scale))
                if let ridgeTarget, let ridgeImage = image(ridgeTarget, alpha: .premultipliedFirst) {
                    ctx.draw(ridgeImage, in: CGRect(x: 0, y: 0, width: ridgeSize.width, height: ridgeSize.height))
                }
                if let out = ctx.makeImage(),
                   let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                              UTType.png.identifier as CFString, 1, nil) {
                    CGImageDestinationAddImage(dest, out, nil)
                    CGImageDestinationFinalize(dest)
                }
            }
        }
        exit(0)
    }
}
