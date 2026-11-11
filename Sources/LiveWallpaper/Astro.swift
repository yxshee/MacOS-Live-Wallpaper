import Foundation

/// Where the sun and moon are, from low-precision almanac series.
///
/// Accuracy is chosen for a picture, not for navigation: the sun is good to a
/// few hundredths of a degree and the moon to about half a degree in position
/// and phase. Refraction and lunar parallax are ignored, so rise and set
/// times can be a few minutes off.
enum Astro {
    struct Body: Equatable {
        var elevation = 0.0      // degrees above the horizon
        var azimuth = 0.0        // degrees clockwise from north
    }

    struct Sky {
        var sun = Body(), moon = Body()
        var hourAngle = 0.0      // sun, radians, negative before solar noon
        var elongation = 0.0     // moon's ecliptic longitude minus the sun's, radians, 0 = new, π = full
        var sidereal = 0.0       // local sidereal angle, radians
    }

    static func sky(at date: Date, latitude: Double, longitude: Double) -> Sky {
        let rad = Double.pi / 180
        let d = date.timeIntervalSince1970 / 86400 + 2440587.5 - 2451545.0     // days since J2000

        // Sun (Astronomical Almanac low-precision formulas).
        let m = (357.529 + 0.98560028 * d) * rad
        let sunLongitude = (280.459 + 0.98564736 * d + 1.915 * sin(m) + 0.020 * sin(2 * m)) * rad
        let eps = (23.439 - 0.00000036 * d) * rad

        // Moon: mean longitude plus the largest periodic terms (Meeus, ch. 47).
        let mm = (134.963 + 13.064993 * d) * rad          // moon's mean anomaly
        let dd = (297.850 + 12.190749 * d) * rad          // mean elongation
        let ff = (93.272 + 13.229350 * d) * rad           // argument of latitude
        let moonLongitude = (218.316 + 13.176396 * d
            + 6.289 * sin(mm) + 1.274 * sin(2 * dd - mm) + 0.658 * sin(2 * dd)
            + 0.214 * sin(2 * mm) - 0.186 * sin(m) - 0.114 * sin(2 * ff)) * rad
        let moonLatitude = (5.128 * sin(ff) + 0.281 * sin(mm + ff)
            + 0.278 * sin(mm - ff) + 0.173 * sin(2 * dd - ff)) * rad

        var lstDeg = ((18.697374558 + 24.06570982441908 * d) * 15 + longitude)
            .truncatingRemainder(dividingBy: 360)
        if lstDeg < 0 { lstDeg += 360 }
        let lst = lstDeg * rad
        let lat = latitude * rad

        /// Ecliptic longitude and latitude to elevation, azimuth and hour angle.
        func place(_ lam: Double, _ beta: Double) -> (Body, Double) {
            let ra = atan2(sin(lam) * cos(eps) - tan(beta) * sin(eps), cos(lam))
            let dec = asin(sin(beta) * cos(eps) + cos(beta) * sin(eps) * sin(lam))
            let h = lst - ra
            let el = asin(sin(lat) * sin(dec) + cos(lat) * cos(dec) * cos(h))
            var az = atan2(-sin(h), tan(dec) * cos(lat) - sin(lat) * cos(h)) / rad
            if az < 0 { az += 360 }
            return (Body(elevation: el / rad, azimuth: az), h)
        }

        let (sun, h) = place(sunLongitude, 0)
        let (moon, _) = place(moonLongitude, moonLatitude)
        var elongation = (moonLongitude - sunLongitude).truncatingRemainder(dividingBy: 2 * .pi)
        if elongation < 0 { elongation += 2 * .pi }
        return Sky(sun: sun, moon: moon, hourAngle: h, elongation: elongation, sidereal: lst)
    }
}
