import Foundation
import Metal
import MetalKit
import simd

/// Matches `LWUniforms` in ScenePrelude.metal field for field.
struct LWUniforms {
    var resolution = V4(), time = V4(), date = V4(), sky = V4(), pointer = V4()
    var frame = SIMD4<Int32>()
    var channelRes0 = V4(), channelRes1 = V4()
}

/// A scene whose picture comes from one fragment shader in a scene folder.
/// Compiles it, binds its textures, and draws it into an off-screen target.
/// Used by the on-screen view and by the headless renderer alike, so
/// `--bench` measures exactly what the wallpaper runs.
final class ShaderScene {
    static let targetFormat = MTLPixelFormat.rgba16Float

    let descriptor: SceneDescriptor
    let folder: URL
    private(set) var pipeline: MTLRenderPipelineState?
    private(set) var failure: String?
    private var channels: [MTLTexture] = []
    private var channelSizes = [V4(), V4()]
    private let pass = MTLRenderPassDescriptor()

    init?(_ descriptor: SceneDescriptor) {
        guard case .shader(let folder) = descriptor.source else { return nil }
        self.descriptor = descriptor
        self.folder = folder
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
    }

    /// The scene file wrapped in a struct, so its functions are methods that
    /// can all see the inputs and its globals are fields (see ScenePrelude.metal).
    static func assemble(prelude: String, scene: String) -> String {
        """
        \(prelude)
        #define in
        struct LWScene {
            float iTime; float iTimeDelta; int iFrame;
            float3 iResolution; float4 iMouse; float4 iDate;
            float3 iChannelResolution[2];
            texture2d<float> iChannel0; texture2d<float> iChannel1;
            float lwSunElevation; float lwSunAzimuth; float lwDaylight; float lwMoon;
        #line 1 "main.metal"
        \(scene)
        };
        #undef in
        fragment float4 lw_fragment(VOut in [[stage_in]], constant LWUniforms &lw [[buffer(0)]],
                                    texture2d<float> c0 [[texture(0)]], texture2d<float> c1 [[texture(1)]]) {
            LWScene s;
            s.iTime = lw.time.x; s.iTimeDelta = lw.time.y; s.iFrame = lw.frame.x;
            s.iResolution = float3(lw.resolution.xy, 1.0);
            s.iMouse = float4(lw.pointer.xy * lw.pointer.z, 0.0, 0.0);
            s.iDate = lw.date;
            s.iChannelResolution[0] = lw.channelRes[0].xyz; s.iChannelResolution[1] = lw.channelRes[1].xyz;
            s.iChannel0 = c0; s.iChannel1 = c1;
            s.lwSunElevation = lw.sky.x; s.lwSunAzimuth = lw.sky.y; s.lwDaylight = lw.sky.z; s.lwMoon = lw.sky.w;
            float4 color = float4(0.0, 0.0, 0.0, 1.0);
            s.mainImage(color, float2(in.pos.x, lw.resolution.y - in.pos.y));     // GLSL's bottom-left origin
            return float4(clamp(color.rgb, 0.0, 16.0), 1.0);
        }
        """
    }

    private func source() throws -> String {
        guard let preludeURL = Bundle.main.url(forResource: "ScenePrelude", withExtension: "metal") else {
            throw NSError(domain: "LiveWallpaper", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "ScenePrelude.metal is missing from the app bundle."])
        }
        return ShaderScene.assemble(
            prelude: try String(contentsOf: preludeURL, encoding: .utf8),
            scene: try String(contentsOf: folder.appendingPathComponent("main.metal"), encoding: .utf8))
    }

    private func pipelineDescriptor(_ library: MTLLibrary) -> MTLRenderPipelineDescriptor {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "lw_vertex")
        d.fragmentFunction = library.makeFunction(name: "lw_fragment")
        d.colorAttachments[0].pixelFormat = ShaderScene.targetFormat
        return d
    }

    private static func describe(_ error: Error) -> String {
        // The compiler's message, without the wrapper lines added around the scene.
        let text = (error as NSError).localizedDescription
        return text.count > 900 ? String(text.prefix(900)) + "…" : text
    }

    /// Blocking compile, for the headless renderer.
    @discardableResult
    func compileNow(_ renderer: Renderer) -> Bool {
        do {
            let library = try renderer.device.makeLibrary(source: try source(), options: nil)
            pipeline = try renderer.device.makeRenderPipelineState(descriptor: pipelineDescriptor(library))
            loadChannels(renderer)
            return true
        } catch {
            failure = ShaderScene.describe(error)
            return false
        }
    }

    /// Compiles off the main thread. A compile that has not finished by the
    /// deadline is reported as failed and its late result ignored, so a shader
    /// the compiler chokes on cannot leave the wallpaper waiting for ever.
    func compile(_ renderer: Renderer, deadline: TimeInterval = 8, completion: @escaping (Bool) -> Void) {
        var settled = false
        func settle(_ ok: Bool, _ why: String? = nil) {
            DispatchQueue.main.async {
                guard !settled else { return }
                settled = true
                if !ok { self.failure = why ?? "The shader could not be compiled." }
                completion(ok)
            }
        }
        let text: String
        do { text = try source() } catch { return settle(false, ShaderScene.describe(error)) }
        DispatchQueue.main.asyncAfter(deadline: .now() + deadline) {
            settle(false, "The shader took more than \(Int(deadline)) seconds to compile.")
        }
        renderer.device.makeLibrary(source: text, options: nil) { library, error in
            guard let library else { return settle(false, error.map(ShaderScene.describe)) }
            renderer.device.makeRenderPipelineState(descriptor: self.pipelineDescriptor(library)) { state, error in
                guard let state else { return settle(false, error.map(ShaderScene.describe)) }
                DispatchQueue.main.async {
                    guard !settled else { return }
                    self.pipeline = state
                    self.loadChannels(renderer)
                    settle(true)
                }
            }
        }
    }

    /// Both texture slots are always bound: a 1×1 black texture stands in for a missing one.
    private func loadChannels(_ renderer: Renderer) {
        let loader = MTKTextureLoader(device: renderer.device)
        channels = []
        for i in 0..<2 {
            var texture = renderer.blackTexture
            if i < descriptor.channels.count {
                let url = folder.appendingPathComponent(descriptor.channels[i])
                if let loaded = try? loader.newTexture(URL: url, options: [
                    .SRGB: false, .generateMipmaps: true, .origin: MTKTextureLoader.Origin.bottomLeft,
                ]) { texture = loaded } else { NSLog("LiveWallpaper: \(descriptor.id): could not load \(descriptor.channels[i])") }
            }
            channels.append(texture)
            channelSizes[i] = V4(Float(texture.width), Float(texture.height), 1, 0)
        }
    }

    func encode(_ buffer: MTLCommandBuffer, target: MTLTexture, uniforms: inout LWUniforms) {
        guard let pipeline, channels.count == 2 else { return }
        uniforms.channelRes0 = channelSizes[0]
        uniforms.channelRes1 = channelSizes[1]
        pass.colorAttachments[0].texture = target
        defer { pass.colorAttachments[0].texture = nil }
        guard let enc = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&uniforms, length: MemoryLayout<LWUniforms>.stride, index: 0)
        enc.setFragmentTexture(channels[0], index: 0)
        enc.setFragmentTexture(channels[1], index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    /// The inputs every shader scene is given, including the real sky, so an
    /// imported scene can follow the actual day if it wants to.
    static func uniforms(pixels: CGSize, pixelsPerPoint: CGFloat, elapsed: Double, delta: Double,
                         frame: Int, cap: Float, date: Date, place: Place) -> LWUniforms {
        var u = LWUniforms()
        u.resolution = V4(Float(pixels.width), Float(pixels.height), Float(pixelsPerPoint),
                          Float(pixels.width / max(pixels.height, 1)))
        u.time = V4(Float(elapsed), Float(delta), cap, 0)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        let seconds = Float((c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60 + (c.second ?? 0)) + Float(c.nanosecond ?? 0) / 1e9
        u.date = V4(Float(c.year ?? 2000), Float((c.month ?? 1) - 1), Float(c.day ?? 1), seconds)
        let sky = Astro.sky(at: date, latitude: place.latitude, longitude: place.longitude)
        let e = Float(sky.sun.elevation)
        u.sky = V4(e, Float(sky.sun.azimuth), smooth(-6, 6, e), Float((1 - cos(sky.elongation)) / 2))
        u.frame = SIMD4<Int32>(Int32(truncatingIfNeeded: frame & 0xFFFFFF), 0, 0, 0)
        return u
    }
}
