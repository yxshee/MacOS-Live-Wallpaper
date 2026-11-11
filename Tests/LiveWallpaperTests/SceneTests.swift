import XCTest
import simd
@testable import LiveWallpaper

final class LayoutContractTests: XCTestCase {
    /// These structs are copied byte for byte into the shaders' uniform buffers.
    func testUniformLayoutMatchesTheShaders() {
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
                XCTAssertGreaterThan(heights.min()!, 0)
                XCTAssertLessThanOrEqual(heights.max()!, t.maxHeight[layer] + 1e-6)
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
        var c = DateComponents()
        c.timeZone = TimeZone(identifier: "UTC")
        (c.year, c.month, c.day) = (2026, 6, 20)
        let start = Calendar(identifier: .gregorian).date(from: c)!
        for (lat, lon) in [(22.5, 88.4), (64.1, -21.9), (69.65, 18.96), (-33.9, 151.2), (0.0, 0.0)] {
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
        let zones = ["Europe/Oslo", "America/New_York", "Asia/Kolkata", "Australia/Sydney"]
        // Midsummer, midwinter, and both clock-change days (a 23-hour and a 25-hour day).
        let days = [(2026, 6, 21), (2026, 12, 21), (2026, 3, 8), (2026, 11, 1), (2026, 3, 29), (2026, 10, 25)]
        for id in zones {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: id)!
            for (lat, lon) in [(69.65, 18.96), (40.7, -74.0), (-33.9, 151.2)] {
                let m = model(lat, lon)
                for (y, mo, d) in days {
                    let noon = cal.date(from: DateComponents(year: y, month: mo, day: d, hour: 12))!
                    let start = cal.startOfDay(for: noon)
                    let end = cal.date(byAdding: .day, value: 1, to: start)!
                    for mode in [SkyMode.dawn, .day, .golden, .dusk, .night] {
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
