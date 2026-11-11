import Foundation

// MARK: - Terrain

/// Six ridge lines, each a height profile stored as one row of a texture
/// (height and slope per texel), built once. Rows wrap, so any screen shape works.
struct Terrain {
    static let width = 16384
    static let layers = 6
    /// Texture periods per screen height. The nearest ridge repeats every four
    /// screen heights, wider than a 32:9 display, so no screen shows a seam.
    static let freq: [Float] = [0.25, 0.21, 0.18, 0.15, 0.13, 0.11]
    private static let foot: [Float] = [0.085, 0.150, 0.215, 0.275, 0.330, 0.375]
    private static let rise: [Float] = [0.060, 0.080, 0.100, 0.120, 0.140, 0.160]
    private static let cells = [18, 16, 14, 12, 12, 10]
    private static let ridged: [Float] = [0.0, 0.1, 0.35, 0.65, 0.9, 1.0]

    private(set) var texels: [Float]
    private(set) var maxHeight = [Float](repeating: 0, count: layers)
    private(set) var offset = [Float](repeating: 0, count: layers)
    private(set) var cabin: (layer: Int, u: Float, y: Float)?
    var top: Float { (maxHeight.max() ?? 0.6) + 0.004 }
    /// Nothing but ridge is ever visible below this height: the farthest range never dips under it.
    static var skyFloor: Float { foot[layers - 1] - 0.004 }

    init(seed: UInt64) {
        let w = Terrain.width
        texels = [Float](repeating: 0, count: w * Terrain.layers * 2)
        var rng = SplitMix(seed: seed)
        for layer in 0..<Terrain.layers {
            var h = Terrain.profile(layer: layer, seed: rng.next())
            if layer < 3 { Terrain.plant(&h, layer: layer, rng: &rng) }
            offset[layer] = rng.unit()
            maxHeight[layer] = h.max() ?? 0
            for k in 0..<w {
                texels[(layer * w + k) * 2] = h[k]
                texels[(layer * w + k) * 2 + 1] = (h[(k + 1) % w] - h[(k + w - 1) % w]) * Float(w) / 2
            }
        }
        cabin = placeCabin()
    }

    /// Wrapping 1-D value noise, summed over octaves; far ranges use the ridged
    /// form for sharp peaks, near ones stay rolling.
    private static func profile(layer: Int, seed: UInt64) -> [Float] {
        let w = width
        let baseCells = cells[layer], rho = ridged[layer]
        let octaves = layer == 0 ? 4 : 6
        let gain: Float = rho > 0.5 ? 0.5 : 0.42
        var rng = SplitMix(seed: seed)
        let lattice = (0..<octaves).map { o in (0..<(baseCells << o)).map { _ in rng.range(-1, 1) } }

        var h = [Float](repeating: 0, count: w)
        for k in 0..<w {
            let x = Float(k) / Float(w)
            var rolling: Float = 0, sharp: Float = 0, amp: Float = 1, norm: Float = 0
            for o in 0..<octaves {
                let p = baseCells << o
                let xp = x * Float(p)
                let i = Int(xp), f = xp - Float(Int(xp))
                let s = f * f * f * (f * (f * 6 - 15) + 10)
                let n = lerp(lattice[o][i % p], lattice[o][(i + 1) % p], s)
                rolling += amp * n
                let r = 1 - min(abs(n) * 1.6, 1)
                sharp += amp * r * r
                norm += amp
                amp *= gain
            }
            h[k] = lerp(0.5 + 0.5 * rolling / norm, sharp / norm, rho)
        }
        let lo = h.min() ?? 0, hi = h.max() ?? 1
        let f0 = foot[layer], r0 = rise[layer]
        return h.map { f0 + r0 * ($0 - lo) / max(hi - lo, 1e-6) }
    }

    /// Pines along the nearer ridges, in patchy woods. A tree is just a taller
    /// stretch of the same height profile, so it costs nothing to draw.
    private static func plant(_ h: inout [Float], layer: Int, rng: inout SplitMix) {
        let w = width
        let ground = h
        let count = [520, 680, 840][layer]
        let scale: Float = [1.0, 0.55, 0.28][layer]
        let patches = 36
        let patch = (0..<patches).map { _ in rng.unit() }
        for j in 0..<count {
            let u = (Float(j) + rng.unit()) / Float(count)
            let tall = rng.range(0.018, 0.052) * scale
            let px = u * Float(patches)
            let pf = px - Float(Int(px))
            let wooded = lerp(patch[Int(px) % patches], patch[(Int(px) + 1) % patches], pf * pf * (3 - 2 * pf))
            if wooded < 0.38 { continue }
            let centre = Int(u * Float(w))
            let span = max(1, Int(tall * 0.24 * freq[layer] * Float(w)))
            let base = ground[centre % w] - tall * 0.12
            for d in -span...span {
                let a = abs(Float(d)) / Float(span)
                let tier = 1 - a - 0.035 * sin(a * 8 * .pi) * (1 - a)
                let k = ((centre + d) % w + w) % w
                h[k] = max(h[k], base + tall * tier)
            }
        }
    }

    func height(_ layer: Int, worldX: Float) -> Float {
        let u = worldX * Terrain.freq[layer] + offset[layer]
        let k = Int((u - u.rounded(.down)) * Float(Terrain.width)) % Terrain.width
        return texels[(layer * Terrain.width + k) * 2]
    }

    /// A spot on the third ridge that the two nearer ridges leave in view.
    private func placeCabin() -> (layer: Int, u: Float, y: Float)? {
        let layer = 2
        for x: Float in [0.34, -0.42, 0.52, -0.20, 0.12, -0.60, 0.66] {
            let y = height(layer, worldX: x) - 0.007
            var clear = true
            for near in 0..<layer {
                for dx: Float in [-0.012, 0, 0.012] where height(near, worldX: x + dx) > y - 0.012 { clear = false }
            }
            if clear { return (layer, x * Terrain.freq[layer] + offset[layer], y) }
        }
        return nil
    }
}
