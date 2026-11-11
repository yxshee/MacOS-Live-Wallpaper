import simd

// MARK: - Palette, keyed by how high the sun is

struct Palette {
    var zenith, horizon, glow, far, near, mist, sun: V3
    var glowAmount, stars: Float

    private static let keys: [(e: Float, p: Palette)] = [
        (-18, Palette(zenith: V3(0.018, 0.030, 0.090), horizon: V3(0.075, 0.125, 0.270), glow: V3(0.20, 0.20, 0.40),
                      far: V3(0.070, 0.110, 0.230), near: V3(0.008, 0.013, 0.032), mist: V3(0.120, 0.175, 0.330),
                      sun: V3(1.00, 0.50, 0.25), glowAmount: 0.00, stars: 1.00)),
        (-12, Palette(zenith: V3(0.024, 0.040, 0.120), horizon: V3(0.140, 0.150, 0.330), glow: V3(0.45, 0.25, 0.45),
                      far: V3(0.105, 0.120, 0.260), near: V3(0.012, 0.016, 0.042), mist: V3(0.190, 0.200, 0.380),
                      sun: V3(1.00, 0.50, 0.25), glowAmount: 0.25, stars: 0.90)),
        (-6, Palette(zenith: V3(0.050, 0.085, 0.250), horizon: V3(0.540, 0.330, 0.430), glow: V3(1.00, 0.45, 0.30),
                     far: V3(0.290, 0.225, 0.380), near: V3(0.026, 0.028, 0.070), mist: V3(0.520, 0.370, 0.480),
                     sun: V3(1.00, 0.50, 0.25), glowAmount: 0.60, stars: 0.40)),
        (-2, Palette(zenith: V3(0.130, 0.190, 0.440), horizon: V3(0.980, 0.560, 0.350), glow: V3(1.00, 0.42, 0.18),
                     far: V3(0.540, 0.350, 0.450), near: V3(0.055, 0.042, 0.095), mist: V3(0.900, 0.560, 0.470),
                     sun: V3(1.00, 0.48, 0.20), glowAmount: 0.90, stars: 0.10)),
        (2, Palette(zenith: V3(0.210, 0.320, 0.610), horizon: V3(1.000, 0.690, 0.420), glow: V3(1.00, 0.52, 0.20),
                    far: V3(0.680, 0.480, 0.510), near: V3(0.085, 0.060, 0.115), mist: V3(1.000, 0.740, 0.560),
                    sun: V3(1.00, 0.52, 0.22), glowAmount: 1.00, stars: 0.00)),
        (8, Palette(zenith: V3(0.240, 0.430, 0.760), horizon: V3(0.990, 0.820, 0.600), glow: V3(1.00, 0.72, 0.40),
                    far: V3(0.690, 0.650, 0.700), near: V3(0.075, 0.115, 0.150), mist: V3(0.980, 0.880, 0.760),
                    sun: V3(1.00, 0.86, 0.60), glowAmount: 0.75, stars: 0.00)),
        (25, Palette(zenith: V3(0.170, 0.430, 0.820), horizon: V3(0.700, 0.860, 0.960), glow: V3(1.00, 0.96, 0.86),
                     far: V3(0.540, 0.700, 0.850), near: V3(0.055, 0.190, 0.225), mist: V3(0.860, 0.930, 0.980),
                     sun: V3(1.00, 0.98, 0.94), glowAmount: 0.30, stars: 0.00)),
        (90, Palette(zenith: V3(0.140, 0.400, 0.820), horizon: V3(0.700, 0.860, 0.960), glow: V3(1.00, 0.96, 0.86),
                     far: V3(0.540, 0.700, 0.850), near: V3(0.055, 0.190, 0.225), mist: V3(0.860, 0.930, 0.980),
                     sun: V3(1.00, 0.98, 0.94), glowAmount: 0.30, stars: 0.00)),
    ]

    static func at(_ e: Float) -> Palette {
        if e <= keys[0].e { return keys[0].p }
        for i in 1..<keys.count where e < keys[i].e {
            let a = keys[i - 1], b = keys[i]
            let t = (e - a.e) / (b.e - a.e)
            return Palette(zenith: lerp(a.p.zenith, b.p.zenith, t), horizon: lerp(a.p.horizon, b.p.horizon, t),
                           glow: lerp(a.p.glow, b.p.glow, t), far: lerp(a.p.far, b.p.far, t),
                           near: lerp(a.p.near, b.p.near, t), mist: lerp(a.p.mist, b.p.mist, t),
                           sun: lerp(a.p.sun, b.p.sun, t),
                           glowAmount: lerp(a.p.glowAmount, b.p.glowAmount, t), stars: lerp(a.p.stars, b.p.stars, t))
        }
        return keys[keys.count - 1].p
    }
}
