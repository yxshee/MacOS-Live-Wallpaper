import Foundation
import simd

// MARK: - The scene

enum SkyMode: String, CaseIterable {
    case real, dawn, day, golden, dusk, night, lapse

    var title: String {
        switch self {
        case .real: return "Follow the Real Sky"
        case .dawn: return "Always Dawn"
        case .day: return "Always Day"
        case .golden: return "Always Golden Hour"
        case .dusk: return "Always Dusk"
        case .night: return "Always Night"
        case .lapse: return "Time-lapse (a day a minute)"
        }
    }
}

/// What the view needs to know about a frame besides its uniforms.
struct FrameInfo {
    var stars: Float             // how visible the stars are, 0...1
    var sunElevation: Float      // degrees
    var cloudCover: Float        // 0 when the sky is clear
    var aurora: Float            // 0 when there is none

    /// Nothing in the sky moves faster than the sun itself.
    var skyIsStill: Bool { stars <= 0.003 && cloudCover <= 0.01 && aurora <= 0.003 }
}

struct FrameInput {
    var date: Date
    var elapsed: Double          // seconds of animation so far
    var aspect: Float
    var parallax: Float          // -0.5...0.5, where the pointer is across the screen
}

/// Turns a date and a place into everything the shaders need. All of it is
/// plain arithmetic on the CPU, a few hundred operations a frame.
final class SceneModel {
    static let shared = SceneModel.fromDefaults()
    static let defaultSeed: UInt64 = 3

    private(set) var place: Place
    private(set) var terrain: Terrain
    private(set) var seed: UInt64
    var skyMode: SkyMode { didSet { pinned = nil; lapseOrigin = Date() } }
    var parallax = true
    var cloudOverride: Float?        // test knobs for the headless renderer
    var auroraOverride: Float?

    private var pinned: (day: Int, date: Date)?
    private var lapseOrigin = Date()
    private var offsetCache: (hour: Int, seconds: Double)?

    init(place: Place, seed: UInt64 = SceneModel.defaultSeed, skyMode: SkyMode = .real) {
        self.place = place
        self.seed = seed
        self.skyMode = skyMode
        terrain = Terrain(seed: seed)
    }

    private static func fromDefaults() -> SceneModel {
        let d = UserDefaults.standard
        let seed = (d.object(forKey: "seed") as? Int).map { UInt64(bitPattern: Int64($0)) } ?? defaultSeed
        // Time-lapse is a demonstration, not a setting: it never survives a relaunch.
        var mode = d.string(forKey: "sky").flatMap { SkyMode(rawValue: $0) } ?? .real
        if mode == .lapse { mode = .real }
        let model = SceneModel(place: currentPlace(), seed: seed, skyMode: mode)
        model.parallax = d.object(forKey: "parallax") as? Bool ?? true
        return model
    }

    /// The user's own coordinates if they set any, otherwise the time zone's city.
    static func currentPlace() -> Place {
        let d = UserDefaults.standard
        if let lat = d.object(forKey: "latitude") as? Double, let lon = d.object(forKey: "longitude") as? Double,
           abs(lat) <= 90, abs(lon) <= 180 {
            return Place(latitude: lat, longitude: lon, source: .manual)
        }
        return Location.place(for: TimeZone.autoupdatingCurrent)
    }

    /// Call after the system time zone or the saved coordinates change.
    func refreshPlace() {
        place = SceneModel.currentPlace()
        pinned = nil
        offsetCache = nil
    }

    /// For the headless renderer and tests: a place that ignores the saved settings.
    func overridePlace(_ newPlace: Place) {
        place = newPlace
        pinned = nil
    }

    func reseed(_ newSeed: UInt64) {
        seed = newSeed
        terrain = Terrain(seed: newSeed)
    }

    /// The moment the sky should show: now, a sped-up clock, or today's dawn/dusk/etc.
    func sceneDate(now: Date = Date()) -> Date {
        switch skyMode {
        case .real:
            return now
        case .lapse:
            return lapseOrigin.addingTimeInterval(now.timeIntervalSince(lapseOrigin) * 1440)
        default:
            let day = Int(localDays(now).rounded(.down))
            if let p = pinned, p.day == day { return p.date }
            let date = moment(for: skyMode, on: now)
            pinned = (day, date)
            return date
        }
    }

    /// Days since the epoch in local time. The UTC offset is looked up once an hour, not once a frame.
    private func localDays(_ date: Date) -> Double {
        let hour = Int((date.timeIntervalSince1970 / 3600).rounded(.down))
        if offsetCache?.hour != hour {
            offsetCache = (hour, Double(TimeZone.autoupdatingCurrent.secondsFromGMT(for: date)))
        }
        return (date.timeIntervalSince1970 + (offsetCache?.seconds ?? 0)) / 86400
    }

    /// Scans the local day minute by minute for the sun height a pinned mode
    /// wants. Where the sun never reaches it (polar summer and winter), the
    /// closest it gets that day is used instead.
    func moment(for mode: SkyMode, on now: Date, calendar: Calendar = .autoupdatingCurrent) -> Date {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        let minutes = max(2, Int(end.timeIntervalSince(start) / 60))        // 23 or 25 hours on clock-change days
        let el = (0..<minutes).map {
            Astro.sky(at: start.addingTimeInterval(Double($0) * 60),
                      latitude: place.latitude, longitude: place.longitude).sun.elevation
        }
        func crossing(_ target: Double, rising: Bool) -> Int {
            let hits = (1..<minutes).filter { rising ? (el[$0 - 1] < target && el[$0] >= target)
                                                     : (el[$0 - 1] >= target && el[$0] < target) }
            if let hit = rising ? hits.first : hits.last { return hit }
            // No crossing today: take the nearest approach on the right side of the day.
            let peak = el.indices.max { el[$0] < el[$1] } ?? minutes / 2
            let side = rising ? Array(0...peak) : Array(peak..<minutes)
            return side.min { abs(el[$0] - target) < abs(el[$1] - target) } ?? peak
        }
        let highest = el.max() ?? 0
        let minute: Int
        switch mode {
        case .dawn: minute = crossing(-4, rising: true)
        case .day: minute = crossing(min(38, highest * 0.75), rising: true)
        case .golden: minute = crossing(9, rising: false)
        case .dusk: minute = crossing(-4, rising: false)
        default: minute = el.indices.min { el[$0] < el[$1] } ?? 0
        }
        return start.addingTimeInterval(Double(minute) * 60)
    }

    /// A value in 0...1 that changes smoothly from one calendar day to the next,
    /// so each day has its own weather without a jump at midnight.
    func daily(_ days: Double, salt: UInt64) -> Float {
        func at(_ n: Double) -> Float {
            var r = SplitMix(seed: UInt64(bitPattern: Int64(n)) &* 0x2545F4914F6CDD1D ^ salt)
            return r.unit()
        }
        let n = days.rounded(.down)
        let f = Float(days - n)
        return lerp(at(n), at(n + 1), f * f * (3 - 2 * f))
    }

    /// Where a body at this elevation and azimuth sits on screen. The view faces
    /// the sun's side of the sky (south in the northern hemisphere, north in the
    /// southern), so the sun rises on one side and sets on the other.
    func project(_ b: Astro.Body, aspect: Float) -> V2 {
        let facing: Double = place.latitude >= 0 ? 180 : 0
        let a = (b.azimuth - facing) * .pi / 180
        let x = sin(a) * cos(b.elevation * .pi / 180) * 0.85 * Double(aspect) / 2
        let y = b.elevation >= 0 ? 0.30 + 0.72 * (1 - exp(-b.elevation / 30))
                                 : 0.30 + b.elevation / 40 * 0.7
        return V2(Float(x), Float(y))
    }

    func uniforms(_ f: FrameInput) -> (Uniforms, FrameInfo) {
        var u = Uniforms()
        let sky = Astro.sky(at: f.date, latitude: place.latitude, longitude: place.longitude)
        let e = Float(sky.sun.elevation)
        var p = Palette.at(e)

        // Dawn is cooler and pinker than dusk, and mistier. The weight fades
        // through solar noon and midnight instead of switching, so high
        // latitudes, where twilight can span either, see no step.
        let morning = smooth(0.15, -0.15, Float(sin(sky.hourAngle)))
        let dawn = max(0, 1 - abs(e) / 12) * morning
        p.glow = lerp(p.glow, V3(1.00, 0.46, 0.56), 0.35 * dawn)
        p.horizon = lerp(p.horizon, simd_min(p.horizon * V3(1.00, 0.93, 1.12), V3(1, 1, 1)), dawn)
        p.mist = lerp(p.mist, V3(0.95, 0.80, 0.86), 0.4 * dawn)

        // Moonlight lifts the night and washes out the faint stars.
        let night = p.stars
        let moonEl = Float(sky.moon.elevation)
        let illuminated = Float((1 - cos(sky.elongation)) / 2)
        let moonUp = smooth(-4, 4, moonEl)
        let moonlight = illuminated * moonUp * night
        p.zenith += V3(0.018, 0.028, 0.055) * moonlight
        p.horizon += V3(0.030, 0.042, 0.075) * moonlight
        p.far += V3(0.035, 0.050, 0.085) * moonlight
        p.mist += V3(0.050, 0.070, 0.110) * moonlight
        let stars = night * (1 - 0.45 * illuminated * moonUp)

        let sunPos = project(sky.sun, aspect: f.aspect)
        let moonPos = project(sky.moon, aspect: f.aspect)
        let days = localDays(f.date)
        // Wind direction and the aurora's pattern belong to the landscape, so
        // they never flip under a running animation.
        let wind: Double = seed & 1 == 0 ? 1 : -1

        u.view = V4(f.aspect, 0, 0, 0.30)
        u.clock = V4(wrap(f.elapsed, 64), wrap(f.elapsed * 0.0019 * wind, 1),
                     wrap(f.elapsed * 0.0031 * wind, 1), wrap(f.elapsed * 0.006, 1))
        u.zenith = V4(sq(p.zenith), stars)
        u.horizon = V4(sq(p.horizon), 0)
        u.glow = V4(sq(p.glow) * p.glowAmount, 1.1 * smooth(24, 3, abs(e)) * smooth(-16, -7, e))
        u.sun = V4(sunPos.x, sunPos.y, 0.026, smooth(-2.5, 0, e))
        u.sunColor = V4(sq(p.sun), 0)

        // The moon's lit limb points at the sun, wherever the sun is.
        var toSun = sunPos - moonPos
        let gap = simd_length(toSun)
        toSun = gap > 1e-4 ? toSun / gap : V2(1, 0)
        let fold = sky.elongation <= .pi ? sky.elongation : 2 * .pi - sky.elongation
        u.moon = V4(moonPos.x, moonPos.y, 0.026, smooth(-3, 0, moonEl) * (0.35 + 0.65 * night))
        u.moonLight = V4(toSun.x * Float(sin(fold)), toSun.y * Float(sin(fold)), Float(-cos(fold)),
                         illuminated * moonUp * (0.15 + 0.85 * night))

        // Stars turn once a sidereal day about the celestial pole on the far
        // side of the view, which sits below the horizon: so they cross the
        // sky the same way the sun does. The Milky Way is an arch around a
        // point near that pole and turns with them.
        let sense: Double = place.latitude >= 0 ? 1 : -1
        u.starRot = V4(Float(cos(sky.sidereal)), Float(sense * sin(sky.sidereal)), 0, -0.45)
        u.milky = V4(0.20, 0.05, 1.30, 1 - 0.5 * illuminated * moonUp)

        let breathing = Float(0.5 + 0.6 * sin(f.elapsed * 2 * .pi / 170 + 1.0) * sin(f.elapsed * 2 * .pi / 67))
        let auroraLevel = auroraOverride
            ?? (0.45 + 0.55 * daily(days, salt: 23)) * min(max(breathing, 0), 1)
        let aurora = auroraLevel * night * (1 - 0.5 * illuminated * moonUp)
        u.aurora = V4(aurora, Float(seed % 997) / 997, 0, 0)

        let cover = (cloudOverride ?? min(0.55, max(0, daily(days, salt: 5) * 1.3 - 0.38) * 0.8)) * (1 - 0.7 * night)
        // Clouds are lit by the sun, then by the moon. The hand-over is a blend,
        // deliberately not re-normalised: when the two pull opposite ways the
        // directional light fades out for a moment instead of whipping round.
        // A body passing right over the reference point fades the light out too.
        func toward(_ source: V2) -> V2 {
            let v = source - V2(0, 0.65)
            return v / max(simd_length(v), 0.15)
        }
        let sunShare = smooth(-10, -2, e)
        let light = toward(moonPos) * (1 - sunShare) + toward(sunPos) * sunShare
        let dayness = smooth(-4, 12, e)
        let lit = lerp(p.horizon, V3(1, 1, 1), 0.55 * dayness) + p.glow * (p.glowAmount * 0.30 * (1 - dayness))
        let shade = lerp(p.zenith, p.horizon, 0.5) * (0.80 + 0.12 * dayness + 0.15 * night)
        u.cloud = V4(cover, light.x, light.y, 0.92 - 0.55 * night)
        u.cloudLit = V4(sq(simd_min(lit, V3(1, 1, 1))), 0)
        u.cloudShade = V4(sq(shade), 0)

        // Ridges: darker and crisper near, paler and mistier far. Morning mist is thicker.
        let mistAmount = 0.55 + 0.45 * morning * max(0, 1 - abs(e - 2) / 12)
        func shift(_ z: Float) -> Float { f.parallax * (0.030 * (1 - z) * (1 - z) + 0.001) }
        for i in 0..<Terrain.layers {
            let z = Float(i) / Float(Terrain.layers - 1)
            let crest = lerp(p.near, p.far, pow(z, 0.8))
            let base = lerp(crest, p.mist, 0.30 + 0.45 * z)
            let fr = Terrain.freq[i]
            var layer = LayerUniforms()
            // The mist creeps: ridges are redrawn every few seconds and each step stays under a point.
            layer.geo = V4(fr, terrain.offset[i] + shift(z) * fr, terrain.maxHeight[i] + 0.002,
                           wrap(f.elapsed * (0.00006 + 0.00002 * Double(i)) * wind, 1))
            layer.crest = V4(sq(crest), z)
            layer.base = V4(sq(base), mistAmount * (0.15 + 0.85 * z))
            u.setLayer(i, layer)
        }

        // The cabin light comes on at dusk and goes out at bedtime, about half
        // past eleven by the sun. It runs on solar time (the hour angle), not
        // the clock, so it is right wherever the clock and the sun disagree
        // and has no seam at midnight.
        if let c = terrain.cabin {
            let fr = Terrain.freq[c.layer]
            let z = Float(c.layer) / Float(Terrain.layers - 1)
            var sinceNoon = sky.hourAngle.truncatingRemainder(dividingBy: 2 * .pi)      // 0 at solar noon, π at midnight
            if sinceNoon < 0 { sinceNoon += 2 * .pi }
            let evening = smooth(0.02, 0.10, Float(sinceNoon)) * smooth(0.965 * .pi, 0.93 * .pi, Float(sinceNoon))
            let on = evening * smooth(-1, -5, e)
            u.cabin = V4((c.u - terrain.offset[c.layer] - shift(z) * fr) / fr, c.y, on, 0)
        }

        u.nebula = V4(wrap(f.elapsed * 0.050, 2 * .pi), wrap(f.elapsed * 0.031, 2 * .pi),
                      wrap(f.elapsed * 0.019, 2 * .pi), 0.55)
        return (u, FrameInfo(stars: stars, sunElevation: e, cloudCover: cover, aurora: aurora))
    }
}
