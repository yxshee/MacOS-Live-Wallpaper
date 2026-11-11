import Foundation
import simd

// Everything the shaders are told each frame is worked out here, on the CPU,
// from the real date: where the sun and moon are, what colour the sky should
// be, how cloudy today is. It is a few hundred arithmetic operations a frame.

typealias V2 = SIMD2<Float>
typealias V3 = SIMD3<Float>
typealias V4 = SIMD4<Float>

func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
func lerp(_ a: V3, _ b: V3, _ t: Float) -> V3 { a + (b - a) * t }
func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
    let t = min(max((x - a) / (b - a), 0), 1)
    return t * t * (3 - 2 * t)
}
/// `x` modulo `period`, always positive. Keeps ever-growing times small enough for a Float.
func wrap(_ x: Double, _ period: Double) -> Float {
    let r = x.truncatingRemainder(dividingBy: period)
    return Float(r < 0 ? r + period : r)
}
func sq(_ c: V3) -> V3 { c * c }

struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Float { Float(next() >> 40) / Float(1 << 24) }
    mutating func range(_ a: Float, _ b: Float) -> Float { a + (b - a) * unit() }
}
