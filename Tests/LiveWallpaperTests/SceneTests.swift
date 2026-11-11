import XCTest
import simd
@testable import LiveWallpaper

final class LayoutContractTests: XCTestCase {
    /// These structs are copied byte for byte into the shaders' uniform buffers.
    /// This checks sizes only: field order still has to be kept in step with
    /// Shaders.metal by hand.
    func testUniformSizesMatchTheShaders() {
        XCTAssertEqual(MemoryLayout<LayerUniforms>.stride, 48)
        XCTAssertEqual(MemoryLayout<Uniforms>.stride, 19 * 16 + Terrain.layers * 48)
        XCTAssertEqual(MemoryLayout<PassInfo>.stride, 16)
        var u = Uniforms()
        var marked = LayerUniforms()
        marked.geo = V4(1, 2, 3, 4)
        u.setLayer(Terrain.layers - 1, marked)
        XCTAssertEqual(u.layers.5.geo, V4(1, 2, 3, 4))
    }

    func testLayersSitOnWholePoints() {
        let terrain = Terrain(seed: SceneModel.defaultSeed)
        for size in [CGSize(width: 2056, height: 1329), CGSize(width: 1080, height: 1920), CGSize(width: 5120, height: 1440)] {
            let l = SceneLayout(size: size, kind: .horizon, terrain: terrain)
            XCTAssertEqual(l.skyBottom, l.skyBottom.rounded())
            XCTAssertEqual(l.ridgeTop, l.ridgeTop.rounded())
            XCTAssertLessThan(l.skyBottom, l.ridgeTop, "the layers must overlap along the skyline")
            XCTAssertLessThanOrEqual(l.ridgeTop, size.height)
        }
        let plain = SceneLayout(size: CGSize(width: 800, height: 600), kind: .nebula, terrain: terrain)
        XCTAssertEqual(plain.skyBottom, 0)
        XCTAssertEqual(plain.ridgeTop, 0)
    }
}

final class TerrainTests: XCTestCase {
    func testSameSeedSameLandscape() {
        XCTAssertEqual(Terrain(seed: 42).texels, Terrain(seed: 42).texels)
        XCTAssertNotEqual(Terrain(seed: 42).texels, Terrain(seed: 43).texels)
    }

    func testHeightsStayInsideTheirLayer() {
        for seed: UInt64 in [1, 7, 99, 123_456] {
            let t = Terrain(seed: seed)
            XCTAssertEqual(t.texels.count, Terrain.width * Terrain.layers * 2)
            for layer in 0..<Terrain.layers {
                let heights = stride(from: 0, to: Terrain.width, by: 1).map { t.texels[(layer * Terrain.width + $0) * 2] }
                // Ground runs from the layer's foot to foot + rise; trees add at most 0.052.
                XCTAssertGreaterThanOrEqual(heights.min()!, Terrain.foot[layer] - 1e-5)
                XCTAssertLessThanOrEqual(heights.max()!, Terrain.foot[layer] + Terrain.rise[layer] + 0.052 + 1e-5)
                XCTAssertEqual(heights.max()!, t.maxHeight[layer], accuracy: 1e-6)
                XCTAssertLessThan(t.maxHeight[layer], t.top)
            }
            // The sky layer starts below the lowest point of the farthest ridge.
            let far = (0..<Terrain.width).map { t.texels[((Terrain.layers - 1) * Terrain.width + $0) * 2] }
            XCTAssertLessThan(Terrain.skyFloor, far.min()!)
        }
    }

    func testNoRidgeRepeatsAcrossAnUltrawideScreen() {
        // A layer's pattern repeats every 1/freq screen heights; 32:9 is 3.56 heights wide.
        XCTAssertLessThanOrEqual(Terrain.freq.max()!, 1 / 3.56)
    }
}

final class PaletteTests: XCTestCase {
    func testColoursNeverJump() {
        var previous = Palette.at(-30)
        var e: Float = -30
        while e < 90 {
            e += 0.05
            let p = Palette.at(e)
            for (a, b) in [(previous.zenith, p.zenith), (previous.horizon, p.horizon), (previous.glow, p.glow),
                           (previous.far, p.far), (previous.near, p.near), (previous.mist, p.mist)] {
                XCTAssertLessThan(simd_reduce_max(simd_abs(a - b)), 0.02, "step at sun elevation \(e)")
            }
            previous = p
        }
        XCTAssertEqual(Palette.at(-40).stars, 1)
        XCTAssertEqual(Palette.at(40).stars, 0)
    }
}

final class SceneModelTests: XCTestCase {
    private func model(_ lat: Double, _ lon: Double) -> SceneModel {
        let m = SceneModel(place: Place(latitude: lat, longitude: lon, source: .manual))
        m.cloudOverride = 0.3
        m.auroraOverride = 0.5
        return m
    }

    /// Walk two days in 30-second steps and make sure no colour or light
    /// direction changes abruptly: at ordinary latitudes, in the far north
    /// (where twilight spans solar midnight) and in the south.
    func testNothingJumpsThroughTheDay() {
        // Solstices, equinoxes and a full-moon night, so every hand-over is crossed.
        for (y, mo, d) in [(2026, 3, 19), (2026, 6, 20), (2026, 9, 22), (2026, 12, 20), (2026, 11, 23)] {
        var c = DateComponents()
        c.timeZone = TimeZone(identifier: "UTC")
        (c.year, c.month, c.day) = (y, mo, d)
        let start = Calendar(identifier: .gregorian).date(from: c)!
        for (lat, lon) in [(22.5, 88.4), (47.4, 8.5), (59.9, 10.7), (64.1, -21.9), (69.65, 18.96), (-33.9, 151.2), (0.0, 0.0)] {
            let m = model(lat, lon)
            var previous: Uniforms?
            for step in 0..<(2 * 2880) {
                let date = start.addingTimeInterval(Double(step) * 30)
                let (u, _) = m.uniforms(FrameInput(date: date, elapsed: 100, aspect: 1.6, parallax: 0))
                if let p = previous {
                    let where_ = "lat \(lat) at \(date)"
                    for (a, b, name) in [(p.zenith, u.zenith, "zenith"), (p.horizon, u.horizon, "horizon"),
                                         (p.glow, u.glow, "glow"), (p.cloudLit, u.cloudLit, "cloud"),
                                         (p.layers.5.base, u.layers.5.base, "mist"),
                                         (p.layers.0.crest, u.layers.0.crest, "ridge")] {
                        XCTAssertLessThan(simd_reduce_max(simd_abs(a - b)), 0.05, "\(name) jumped, \(where_)")
                    }
                    XCTAssertLessThan(abs(p.cloud.y - u.cloud.y) + abs(p.cloud.z - u.cloud.z), 0.12, "cloud light jumped, \(where_)")
                    XCTAssertLessThan(abs(p.cabin.z - u.cabin.z), 0.08, "cabin light jumped, \(where_)")
                }
                previous = u
            }
        }
        }
    }

    func testSunCrossesTheSameWayInBothHemispheres() {
        // Morning sun on one side, evening sun on the other, mirrored south of the equator.
        var c = DateComponents()
        c.timeZone = TimeZone(identifier: "UTC")
        (c.year, c.month, c.day, c.hour) = (2026, 3, 20, 7)
        let morningAtGreenwich = Calendar(identifier: .gregorian).date(from: c)!
        let north = model(51.5, 0), south = model(-51.5, 0)
        let (un, _) = north.uniforms(FrameInput(date: morningAtGreenwich, elapsed: 0, aspect: 1.6, parallax: 0))
        let (us, _) = south.uniforms(FrameInput(date: morningAtGreenwich, elapsed: 0, aspect: 1.6, parallax: 0))
        XCTAssertLessThan(un.sun.x, -0.2, "facing south, the morning sun is on the left")
        XCTAssertGreaterThan(us.sun.x, 0.2, "facing north, it is on the right")
        // And the stars turn with it: opposite senses in the two hemispheres.
        XCTAssertEqual(un.starRot.y, -us.starRot.y, accuracy: 1e-6)
    }

    func testPinnedSkiesAlwaysResolveInsideTheDay() {
        // Each place with its own time zone: Tromsø (polar day and night), New York,
        // Kolkata (no clock changes) and Sydney (southern, clocks change the other way).
        let places = [("Europe/Oslo", 69.65, 18.96), ("America/New_York", 40.7, -74.0),
                      ("Asia/Kolkata", 22.53, 88.37), ("Australia/Sydney", -33.9, 151.2)]
        // Midsummer, midwinter, and clock-change days (23-hour and 25-hour days).
        let days = [(2026, 6, 21), (2026, 12, 21), (2026, 3, 8), (2026, 11, 1), (2026, 3, 29), (2026, 10, 25),
                    (2026, 4, 5), (2026, 10, 4)]
        for (id, lat, lon) in places {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: id)!
            do {
                let m = model(lat, lon)
                for (y, mo, d) in days {
                    let noon = cal.date(from: DateComponents(year: y, month: mo, day: d, hour: 12))!
                    let start = cal.startOfDay(for: noon)
                    let end = cal.date(byAdding: .day, value: 1, to: start)!
                    // The day as the model scans it: one elevation per minute.
                    let minutes = Int(end.timeIntervalSince(start) / 60)
                    let el = (0..<minutes).map {
                        Astro.sky(at: start.addingTimeInterval(Double($0) * 60), latitude: lat, longitude: lon).sun.elevation
                    }
                    for (mode, target) in [(SkyMode.dawn, -4.0), (.golden, 9.0), (.dusk, -4.0)] {
                        let t = m.moment(for: mode, on: noon, calendar: cal)
                        let label = "\(mode) at \(lat) on \(y)-\(mo)-\(d) in \(id)"
                        XCTAssertTrue(t >= start && t < end, "\(label) fell outside the day")
                        let got = Astro.sky(at: t, latitude: lat, longitude: lon).sun.elevation
                        if el.min()! < target && el.max()! > target {
                            // The sun does pass this height today, so the moment must sit on it.
                            XCTAssertEqual(got, target, accuracy: 0.6, label)
                        } else {
                            // It never does: the moment must be no worse than the day's closest approach.
                            let nearest = el.map { abs($0 - target) }.min()!
                            XCTAssertLessThanOrEqual(abs(got - target), nearest + 2, label)
                        }
                    }
                    for mode in [SkyMode.day, .night] {
                        let t = m.moment(for: mode, on: noon, calendar: cal)
                        XCTAssertTrue(t >= start && t < end, "\(mode) at \(lat) on \(y)-\(mo)-\(d) in \(id) fell outside the day")
                    }
                }
            }
        }
    }

    func testPinnedSkiesFindTheRightLight() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let m = model(22.53, 88.37)
        let noon = cal.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 12))!
        func elevation(_ mode: SkyMode) -> Double {
            Astro.sky(at: m.moment(for: mode, on: noon, calendar: cal), latitude: 22.53, longitude: 88.37).sun.elevation
        }
        XCTAssertEqual(elevation(.dawn), -4, accuracy: 0.5)
        XCTAssertEqual(elevation(.dusk), -4, accuracy: 0.5)
        XCTAssertEqual(elevation(.golden), 9, accuracy: 0.5)
        XCTAssertEqual(elevation(.day), 38, accuracy: 0.5)       // the lower of 38° and three quarters of the noon height
        XCTAssertLessThan(elevation(.night), -40)
        XCTAssertLessThan(m.moment(for: .dawn, on: noon, calendar: cal), m.moment(for: .dusk, on: noon, calendar: cal))
    }

    func testAClearDayIsStillAndANightIsNot() {
        let m = SceneModel(place: Place(latitude: 22.5, longitude: 88.4, source: .manual))
        m.cloudOverride = 0
        var c = DateComponents()
        c.timeZone = TimeZone(identifier: "UTC")
        (c.year, c.month, c.day, c.hour) = (2026, 11, 10, 6)       // late morning in India
        let day = Calendar(identifier: .gregorian).date(from: c)!
        XCTAssertTrue(m.uniforms(FrameInput(date: day, elapsed: 5, aspect: 1.6, parallax: 0)).1.skyIsStill)
        let night = day.addingTimeInterval(12 * 3600)
        XCTAssertFalse(m.uniforms(FrameInput(date: night, elapsed: 5, aspect: 1.6, parallax: 0)).1.skyIsStill)
    }

    func testDailyWeatherIsContinuousAcrossMidnight() {
        let m = model(0, 0)
        for day in [-3.0, 0.0, 20_000.0] {
            XCTAssertEqual(m.daily(day - 1e-6, salt: 5), m.daily(day + 1e-6, salt: 5), accuracy: 1e-3)
        }
    }
}
