import simd

// MARK: - Uniforms (must match Shaders.metal field for field)

struct LayerUniforms {
    var geo = V4(), crest = V4(), base = V4()
}

struct Uniforms {
    var view = V4(), clock = V4(), zenith = V4(), horizon = V4(), glow = V4()
    var sun = V4(), sunColor = V4(), moon = V4(), moonLight = V4(), starRot = V4()
    var milky = V4(), aurora = V4(), cloud = V4(), cloudLit = V4(), cloudShade = V4()
    var meteorA = V4(), meteorB = V4(), cabin = V4(), nebula = V4()
    var layers = (LayerUniforms(), LayerUniforms(), LayerUniforms(),
                  LayerUniforms(), LayerUniforms(), LayerUniforms())

    mutating func setLayer(_ i: Int, _ layer: LayerUniforms) {
        withUnsafeMutableBytes(of: &layers) { $0.bindMemory(to: LayerUniforms.self)[i] = layer }
    }
}
