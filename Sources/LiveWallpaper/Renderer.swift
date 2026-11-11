import AppKit
import Metal

// MARK: - Renderer

enum SceneKind { case horizon, nebula }

/// Matches `Pass` in Shaders.metal: scene height at the bottom and top of the
/// strip being drawn, pixels per scene height, pixels per point.
struct PassInfo {
    var r = V4()
}

/// Where the two layers sit, in whole points so both land on the pixel grid.
/// The sky is only ever visible above the lowest point of the farthest ridge,
/// and the ridges only below the highest peak, so each layer covers just that.
struct SceneLayout {
    var skyBottom: CGFloat = 0
    var ridgeTop: CGFloat = 0

    init(size: CGSize, kind: SceneKind, terrain: Terrain) {
        guard kind == .horizon else { return }
        skyBottom = (CGFloat(Terrain.skyFloor) * size.height).rounded(.down)
        ridgeTop = min(size.height, (CGFloat(terrain.top) * size.height).rounded(.up) + 2)
    }
}

final class Renderer {
    static let shared: Renderer? = Renderer()
    /// Why `shared` is nil, when it is.
    private(set) static var failure: String?
    /// GPU milliseconds for a recent ordinary frame and a recent ridge redraw. Main thread only.
    static var skyMillis = 0.0
    static var ridgeMillis = 0.0

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let skyPipeline, nebulaPipeline, starsPipeline, plainPipeline, ridgePipeline: MTLRenderPipelineState
    private let noise: MTLTexture
    private var ridges: MTLTexture
    private let descriptor = MTLRenderPassDescriptor()

    private init?() {
        guard let device = Renderer.pickDevice(), let queue = device.makeCommandQueue() else {
            Renderer.failure = "This Mac has no Metal graphics device available."
            return nil
        }
        guard device.supports32BitFloatFiltering else {
            Renderer.failure = "The graphics device \(device.name) cannot filter 32-bit float textures."
            return nil
        }
        do {
            let library = try Renderer.loadLibrary(device)
            func pipeline(_ fragment: String, _ format: MTLPixelFormat) throws -> MTLRenderPipelineState {
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = library.makeFunction(name: "fullscreen")
                d.fragmentFunction = library.makeFunction(name: fragment)
                d.colorAttachments[0].pixelFormat = format
                return try device.makeRenderPipelineState(descriptor: d)
            }
            skyPipeline = try pipeline("skyFragment", .rgba16Float)
            nebulaPipeline = try pipeline("nebulaFragment", .rgba16Float)
            starsPipeline = try pipeline("starsFragment", .bgra8Unorm)
            plainPipeline = try pipeline("plainFragment", .bgra8Unorm)
            ridgePipeline = try pipeline("ridgeFragment", .bgra8Unorm)
        } catch {
            NSLog("LiveWallpaper: shader setup failed: \(error)")
            Renderer.failure = "The shaders could not be compiled: \(error.localizedDescription)"
            return nil
        }

        let nd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg16Unorm, width: NoiseBake.size,
                                                          height: NoiseBake.size, mipmapped: false)
        guard let noise = device.makeTexture(descriptor: nd),
              let ridges = Renderer.makeRidges(device, SceneModel.shared.terrain) else {
            Renderer.failure = "The graphics device \(device.name) could not allocate the scene's textures."
            return nil
        }
        NoiseBake.make().withUnsafeBytes {
            noise.replace(region: MTLRegionMake2D(0, 0, NoiseBake.size, NoiseBake.size), mipmapLevel: 0,
                          withBytes: $0.baseAddress!, bytesPerRow: NoiseBake.size * 4)
        }
        self.device = device
        self.queue = queue
        self.noise = noise
        self.ridges = ridges
        descriptor.colorAttachments[0].loadAction = .dontCare
        descriptor.colorAttachments[0].storeAction = .store
    }

    /// The integrated GPU when there is a choice: on a dual-GPU laptop the
    /// system default is the discrete one, and a wallpaper must never be the
    /// reason that stays powered.
    private static func pickDevice() -> MTLDevice? {
        let all = MTLCopyAllDevices()
        return all.first { $0.isLowPower && !$0.isRemovable } ?? MTLCreateSystemDefaultDevice() ?? all.first
    }

    private static func loadLibrary(_ device: MTLDevice) throws -> MTLLibrary {
        if let url = Bundle.main.url(forResource: "default", withExtension: "metallib") {
            return try device.makeLibrary(URL: url)
        }
        guard let url = Bundle.main.url(forResource: "Shaders", withExtension: "metal") else {
            throw NSError(domain: "LiveWallpaper", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Shaders.metal is missing. Run the app from LiveWallpaper.app, which carries it in Contents/Resources."])
        }
        return try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
    }

    private static func makeRidges(_ device: MTLDevice, _ terrain: Terrain) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg32Float, width: Terrain.width,
                                                         height: Terrain.layers, mipmapped: false)
        guard let texture = device.makeTexture(descriptor: d) else { return nil }
        terrain.texels.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, Terrain.width, Terrain.layers), mipmapLevel: 0,
                            withBytes: $0.baseAddress!, bytesPerRow: Terrain.width * 8)
        }
        return texture
    }

    func terrainChanged() {
        if let t = Renderer.makeRidges(device, SceneModel.shared.terrain) { ridges = t }
    }

    func makeBuffer() -> MTLCommandBuffer? { queue.makeCommandBuffer() }

    /// The small off-screen target for the soft sky: half the sky layer's points each way.
    func makeSoftTarget(pointSize: CGSize) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                         width: max(32, Int(pointSize.width / 2)),
                                                         height: max(32, Int(pointSize.height / 2)),
                                                         mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        return device.makeTexture(descriptor: d)
    }

    /// The soft sky into `soft` (when `refreshSoft`), then the finished sky layer into `target`.
    func encodeSky(_ buffer: MTLCommandBuffer, target: MTLTexture, soft: MTLTexture, refreshSoft: Bool = true,
                   uniforms: inout Uniforms, kind: SceneKind, pass: PassInfo) {
        if refreshSoft {
            draw(buffer, soft, kind == .horizon ? skyPipeline : nebulaPipeline, &uniforms, pass, noise, nil)
        }
        if kind == .horizon {
            draw(buffer, target, starsPipeline, &uniforms, pass, soft, noise)
        } else {
            draw(buffer, target, plainPipeline, &uniforms, pass, soft, nil)
        }
    }

    func encodeRidges(_ buffer: MTLCommandBuffer, target: MTLTexture, uniforms: inout Uniforms, pass: PassInfo) {
        draw(buffer, target, ridgePipeline, &uniforms, pass, ridges, noise)
    }

    private func draw(_ buffer: MTLCommandBuffer, _ target: MTLTexture, _ pipeline: MTLRenderPipelineState,
                      _ uniforms: inout Uniforms, _ pass: PassInfo, _ t0: MTLTexture, _ t1: MTLTexture?) {
        descriptor.colorAttachments[0].texture = target
        defer { descriptor.colorAttachments[0].texture = nil }      // don't hold on to a drawable
        guard let enc = buffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        var pass = pass
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setFragmentBytes(&pass, length: MemoryLayout<PassInfo>.stride, index: 1)
        enc.setFragmentTexture(t0, index: 0)
        if let t1 { enc.setFragmentTexture(t1, index: 1) }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }
}
