import Foundation

// MARK: - Baked noise

/// A 512² tile of two independent, seamlessly wrapping Perlin fBm fields.
/// Baked once at launch; after that every "noise" in the shaders is one lookup.
enum NoiseBake {
    static let size = 512

    static func make() -> [UInt16] {
        let size = NoiseBake.size, octaves = 5, basePeriod = 4
        var tables = [[Float]]()                    // unit gradients, per channel and octave
        for channel in 0..<2 {
            for o in 0..<octaves {
                let p = basePeriod << o
                var rng = SplitMix(seed: UInt64(1000 + channel * 100 + o))
                var t = [Float](repeating: 0, count: p * p * 2)
                for i in 0..<(p * p) {
                    let a = rng.unit() * 2 * Float.pi
                    t[2 * i] = cos(a)
                    t[2 * i + 1] = sin(a)
                }
                tables.append(t)
            }
        }

        var field = [Float](repeating: 0, count: size * size * 2)
        field.withUnsafeMutableBufferPointer { buf in
            let out = buf.baseAddress!
            DispatchQueue.concurrentPerform(iterations: size) { y in
                for x in 0..<size {
                    let u = (Float(x) + 0.5) / Float(size), v = (Float(y) + 0.5) / Float(size)
                    for channel in 0..<2 {
                        var sum: Float = 0, amp: Float = 1
                        for o in 0..<octaves {
                            let p = basePeriod << o
                            sum += amp * perlin(u * Float(p), v * Float(p), p, tables[channel * octaves + o])
                            amp *= 0.5
                        }
                        out[(y * size + x) * 2 + channel] = sum
                    }
                }
            }
        }

        var result = [UInt16](repeating: 0, count: field.count)
        for channel in 0..<2 {
            var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
            for i in stride(from: channel, to: field.count, by: 2) { lo = min(lo, field[i]); hi = max(hi, field[i]) }
            for i in stride(from: channel, to: field.count, by: 2) {
                result[i] = UInt16(max(0, min(65535, (field[i] - lo) / (hi - lo) * 65535)))
            }
        }
        return result
    }

    private static func perlin(_ x: Float, _ y: Float, _ p: Int, _ t: [Float]) -> Float {
        let xf = x.rounded(.down), yf = y.rounded(.down)
        let x0 = Int(xf) % p, y0 = Int(yf) % p
        let x1 = (x0 + 1) % p, y1 = (y0 + 1) % p
        let fx = x - xf, fy = y - yf
        func corner(_ ix: Int, _ iy: Int, _ dx: Float, _ dy: Float) -> Float {
            let i = (iy * p + ix) * 2
            return t[i] * dx + t[i + 1] * dy
        }
        let u = fx * fx * fx * (fx * (fx * 6 - 15) + 10)
        let v = fy * fy * fy * (fy * (fy * 6 - 15) + 10)
        let top = lerp(corner(x0, y0, fx, fy), corner(x1, y0, fx - 1, fy), u)
        let bottom = lerp(corner(x0, y1, fx, fy - 1), corner(x1, y1, fx - 1, fy - 1), u)
        return lerp(top, bottom, v)
    }
}
