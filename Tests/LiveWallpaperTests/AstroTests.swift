import XCTest
@testable import LiveWallpaper

private func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
    var c = DateComponents()
    c.timeZone = TimeZone(identifier: "UTC")
    (c.year, c.month, c.day, c.hour, c.minute) = (y, mo, d, h, mi)
    return Calendar(identifier: .gregorian).date(from: c)!
}

final class AstroTests: XCTestCase {
    func testSunAtGreenwichOnTheEquinox() {
        let s = Astro.sky(at: utc(2026, 3, 20, 12, 7), latitude: 51.48, longitude: 0)
        XCTAssertEqual(s.sun.elevation, 38.5, accuracy: 0.5)       // 90 - latitude
        XCTAssertEqual(s.sun.azimuth, 180, accuracy: 1.5)
        XCTAssertEqual(sin(s.hourAngle), 0, accuracy: 0.03)
    }

    func testSunriseOnTheEquator() {
        // Quito, equinox: the sun crosses the horizon about 06:15 local (UTC-5), due east.
        let s = Astro.sky(at: utc(2026, 3, 20, 11, 15), latitude: -0.2, longitude: -78.5)
        XCTAssertEqual(s.sun.elevation, 0, accuracy: 2)
        XCTAssertEqual(s.sun.azimuth, 90, accuracy: 2)
        XCTAssertLessThan(sin(s.hourAngle), 0, "morning has a negative hour angle")
    }

    func testSouthernNoonSunIsInTheNorth() {
        // Sydney, December solstice, solar noon is close to 01:55 UTC.
        let s = Astro.sky(at: utc(2026, 12, 21, 1, 55), latitude: -33.87, longitude: 151.21)
        XCTAssertEqual(s.sun.elevation, 79.6, accuracy: 0.7)
        XCTAssertTrue(s.sun.azimuth < 25 || s.sun.azimuth > 335, "azimuth \(s.sun.azimuth) should be northerly")
    }

    func testPolarDayAndPolarNight() {
        // Tromsø: the midsummer sun is up at solar midnight, the midwinter sun down at solar noon.
        let midnightSun = Astro.sky(at: utc(2026, 6, 21, 22, 45), latitude: 69.65, longitude: 18.96)
        XCTAssertGreaterThan(midnightSun.sun.elevation, 1)
        let polarNoon = Astro.sky(at: utc(2026, 12, 21, 10, 45), latitude: 69.65, longitude: 18.96)
        XCTAssertLessThan(polarNoon.sun.elevation, -1)
    }

    func testMoonPhasesMatchTheAlmanac() {
        let rad = 180 / Double.pi
        let new = Astro.sky(at: utc(2026, 11, 9, 7, 2), latitude: 0, longitude: 0).elongation * rad
        XCTAssertTrue(new < 3 || new > 357, "new moon elongation \(new)")
        let full = Astro.sky(at: utc(2026, 11, 24, 14, 53), latitude: 0, longitude: 0).elongation * rad
        XCTAssertEqual(full, 180, accuracy: 3)
        let quarter = Astro.sky(at: utc(2026, 11, 17, 11, 48), latitude: 0, longitude: 0).elongation * rad
        XCTAssertEqual(quarter, 90, accuracy: 3)
    }

    func testFullMoonRisesAsTheSunSets() {
        // Opposite the sun: when one is on the horizon the other is near it too.
        let s = Astro.sky(at: utc(2026, 11, 24, 17, 0), latitude: 40, longitude: 0)
        XCTAssertEqual(s.sun.elevation + s.moon.elevation, 0, accuracy: 9)
        XCTAssertGreaterThan(abs(s.sun.azimuth - s.moon.azimuth), 150)
    }
}

final class LocationTests: XCTestCase {
    func testCoordinateParsing() {
        let kolkata = Location.parseISO6709("+2232+08822")!
        XCTAssertEqual(kolkata.latitude, 22.533, accuracy: 0.01)
        XCTAssertEqual(kolkata.longitude, 88.367, accuracy: 0.01)
        let buenosAires = Location.parseISO6709("-3436-05827")!
        XCTAssertEqual(buenosAires.latitude, -34.6, accuracy: 0.01)
        XCTAssertEqual(buenosAires.longitude, -58.45, accuracy: 0.01)
        let withSeconds = Location.parseISO6709("+404251-0740023")!
        XCTAssertEqual(withSeconds.latitude, 40.714, accuracy: 0.01)
        XCTAssertEqual(withSeconds.longitude, -74.006, accuracy: 0.01)
        XCTAssertNil(Location.parseISO6709("garbage"))
        XCTAssertNil(Location.parseISO6709("+9999+99999"))
    }

    func testZoneCityAndAlias() throws {
        let table = Location.zoneTable()
        try XCTSkipIf(table.isEmpty, "no zoneinfo table on this machine")
        let kolkata = Location.place(for: TimeZone(identifier: "Asia/Kolkata")!)
        XCTAssertEqual(kolkata.source, .zoneCity("Asia/Kolkata"))
        XCTAssertEqual(kolkata.latitude, 22.53, accuracy: 0.05)

        // The old name is not in the table; it must resolve to the city that replaced it.
        let calcutta = Location.place(for: TimeZone(identifier: "Asia/Calcutta")!)
        XCTAssertEqual(calcutta.source, .zoneCity("Asia/Kolkata"))
        XCTAssertEqual(calcutta.latitude, kolkata.latitude)
    }

    func testEveryZoneMacOSOffersHasACity() throws {
        let table = Location.zoneTable()
        try XCTSkipIf(table.isEmpty, "no zoneinfo table on this machine")
        for id in TimeZone.knownTimeZoneIdentifiers where id != "GMT" {
            let place = Location.place(for: TimeZone(identifier: id)!)
            XCTAssertNotEqual(place.source, .offsetGuess, "\(id) fell back to a guess")
        }
        // Every successor named in the legacy list must exist, or the list is stale.
        for (old, new) in Location.legacyNames where TimeZone(identifier: old) != nil {
            XCTAssertNotNil(table[new], "\(old) points at \(new), which the table does not have")
        }
    }

    func testAliasWithSharedRulesPicksAnInhabitedPlace() throws {
        try XCTSkipIf(Location.zoneTable().isEmpty, "no zoneinfo table on this machine")
        // "NZ" shares its rule file with Pacific/Auckland and Antarctica/McMurdo.
        guard let nz = TimeZone(identifier: "NZ") else { throw XCTSkip("no NZ alias here") }
        let place = Location.place(for: nz)
        XCTAssertGreaterThan(place.latitude, -50, "resolved to Antarctica")
        XCTAssertLessThan(place.latitude, -30)
    }

    func testFallbackUsesStandardOffset() {
        // An empty zoneinfo directory forces the last resort.
        let empty = NSTemporaryDirectory() + "lw-empty-zoneinfo-\(getpid())"
        try? FileManager.default.createDirectory(atPath: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: empty) }
        let p = Location.place(for: TimeZone(identifier: "America/New_York")!, zoneinfo: empty)
        XCTAssertEqual(p.source, .offsetGuess)
        XCTAssertEqual(p.longitude, -75, accuracy: 0.01, "UTC-5 standard time, whatever the season")
    }
}
