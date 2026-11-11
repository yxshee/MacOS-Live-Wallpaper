import AppKit
import Metal
import ImageIO
import UniformTypeIdentifiers

/// Reading a rendered texture back and writing it out.
enum Snapshot {
    /// The texture's bytes (BGRA), read through a blit into a CPU-visible
    /// buffer, which works the same on unified-memory and discrete GPUs.
    static func pixels(of texture: MTLTexture, renderer: Renderer) -> [UInt8]? {
        let rowBytes = texture.width * 4, length = rowBytes * texture.height
        guard let store = renderer.device.makeBuffer(length: length, options: .storageModeShared),
              let buffer = renderer.makeBuffer(), let blit = buffer.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                  to: store, destinationOffset: 0, destinationBytesPerRow: rowBytes, destinationBytesPerImage: length)
        blit.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        return [UInt8](UnsafeBufferPointer(start: store.contents().assumingMemoryBound(to: UInt8.self), count: length))
    }

    static func image(bgra: [UInt8], width: Int, height: Int, alpha: CGImageAlphaInfo = .noneSkipFirst) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bgra) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | alpha.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    @discardableResult
    static func write(_ image: CGImage, to path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        let type = ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) ? UTType.jpeg : UTType.png
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }
}

/// Off-screen rendering of shader scenes: one frame to a file, a timing run,
/// or a pass over every scene in the library.
enum HeadlessShader {
    struct Outcome {
        var failure: String?
        var gpuMillis = 0.0
        var image: CGImage?
        var drawn = CGSize.zero          // the off-screen size the scene itself was drawn at
        var varied = false               // the picture is not one flat colour
    }

    /// Draws `frames` frames the way the wallpaper does: the scene at its own
    /// resolution, then scaled up to `width` × `height`.
    static func draw(_ descriptor: SceneDescriptor, renderer: Renderer, width: Int, height: Int, scale: CGFloat,
                     elapsed: Double, date: Date, frames: Int, place: Place) -> Outcome {
        var outcome = Outcome()
        guard let scene = ShaderScene(descriptor) else {
            outcome.failure = "not a shader scene"
            return outcome
        }
        guard scene.compileNow(renderer) else {
            outcome.failure = scene.failure ?? "the shader could not be compiled"
            return outcome
        }
        let points = CGSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        let drawScale = min(CGFloat(descriptor.scale), scale)
        let size = CGSize(width: max(16, (points.width * drawScale).rounded()), height: max(16, (points.height * drawScale).rounded()))
        outcome.drawn = size
        guard let target = renderer.makeTarget(width: Int(size.width), height: Int(size.height), format: ShaderScene.targetFormat),
              let screen = renderer.makeTarget(width: width, height: height, format: .bgra8Unorm) else {
            outcome.failure = "could not create render targets"
            return outcome
        }
        // Queued back to back, so the GPU stays at full clock speed and the time reflects the work.
        var buffers = [MTLCommandBuffer]()
        for i in 0..<max(1, frames) {
            guard let buffer = renderer.makeBuffer() else { continue }
            var u = ShaderScene.uniforms(pixels: size, pixelsPerPoint: drawScale, elapsed: elapsed + Double(i) / 20,
                                         delta: 0.05, frame: i, cap: descriptor.maxFPS, date: date, place: place)
            scene.encode(buffer, target: target, uniforms: &u)
            renderer.encodePresent(buffer, source: target, target: screen)
            buffer.commit()
            buffers.append(buffer)
        }
        buffers.last?.waitUntilCompleted()
        if let failed = buffers.first(where: { $0.status == .error }) {
            outcome.failure = "the GPU rejected a frame: \(failed.error?.localizedDescription ?? "unknown error")"
            return outcome
        }
        if let first = buffers.first, let lastBuffer = buffers.last {
            let warm = buffers[buffers.count / 4]
            outcome.gpuMillis = buffers.count < 8
                ? (lastBuffer.gpuEndTime - first.gpuStartTime) * 1000 / Double(buffers.count)
                : (lastBuffer.gpuEndTime - warm.gpuStartTime) * 1000 / Double(buffers.count - buffers.count / 4)
        }
        if let bytes = Snapshot.pixels(of: screen, renderer: renderer) {
            var lo = 255, hi = 0
            for i in stride(from: 0, to: bytes.count - 4, by: 4 * 97) {
                let v = (Int(bytes[i]) + Int(bytes[i + 1]) + Int(bytes[i + 2])) / 3
                lo = min(lo, v); hi = max(hi, v)
            }
            outcome.varied = hi - lo >= 6
            outcome.image = Snapshot.image(bgra: bytes, width: width, height: height)
        }
        return outcome
    }

    /// `--render` / `--bench` for one shader scene.
    static func run(_ descriptor: SceneDescriptor, renderer: Renderer, width: Int, height: Int, scale: CGFloat,
                    elapsed: Double, date: Date, frames: Int, path: String?, place: Place) -> Never {
        let o = draw(descriptor, renderer: renderer, width: width, height: height, scale: scale,
                     elapsed: elapsed, date: date, frames: frames, place: place)
        if let failure = o.failure {
            FileHandle.standardError.write(Data("\(descriptor.id): \(failure)\n".utf8))
            exit(1)
        }
        if frames > 1 {
            print(String(format: "%@: %.3f ms per frame (drawn at %d×%d, shown at %d×%d)",
                         descriptor.id, o.gpuMillis, Int(o.drawn.width), Int(o.drawn.height), width, height))
        }
        if let path {
            guard let image = o.image, Snapshot.write(image, to: path) else {
                FileHandle.standardError.write(Data("\(path) could not be written\n".utf8))
                exit(1)
            }
        }
        if !o.varied { FileHandle.standardError.write(Data("\(descriptor.id): the frame is a single flat colour\n".utf8)) }
        exit(o.varied ? 0 : 1)
    }

    /// `--check-scenes [--previews DIR]`: compile and draw every shader scene,
    /// report its cost, and fail if any does not compile or draws nothing.
    static func checkAll(renderer: Renderer, registry: SceneRegistry, previews: String?, place: Place) -> Never {
        var failures = registry.problems
        let noon = Calendar.current.startOfDay(for: Date()).addingTimeInterval(13 * 3600)
        for d in registry.scenes {
            guard case .shader = d.source else { continue }
            let o = draw(d, renderer: renderer, width: 2056, height: 1329, scale: 1, elapsed: 30, date: noon,
                         frames: 60, place: place)
            if let failure = o.failure {
                failures.append("\(d.id): \(failure)")
                print("FAIL  \(d.id)")
                continue
            }
            if !o.varied { failures.append("\(d.id): the frame is a single flat colour") }
            print(String(format: "%@  %-28@ %6.3f ms/frame at %4d×%-4d  ×%2.0f fps = %5.1f ms/s  %@",
                         o.varied ? "ok  " : "FLAT", d.id as NSString, o.gpuMillis, Int(o.drawn.width), Int(o.drawn.height),
                         d.maxFPS, o.gpuMillis * Double(d.maxFPS), d.licence as NSString))
            if let previews {
                let path = "\(previews)/\(d.id).jpg"
                if let image = o.image, let small = shrink(image, width: 640), Snapshot.write(small, to: path) {} else {
                    failures.append("\(path) could not be written")
                }
            }
        }
        for f in failures { FileHandle.standardError.write(Data((f + "\n").utf8)) }
        exit(failures.isEmpty ? 0 : 1)
    }

    static func shrink(_ image: CGImage, width: Int) -> CGImage? {
        let height = max(1, image.height * width / max(image.width, 1))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }
}
