import Foundation

/// The spot on Earth the sky is computed for.
struct Place: Equatable {
    enum Source: Equatable {
        case manual                  // typed in by the user
        case zoneCity(String)        // the time zone's reference city
        case offsetGuess             // nothing better than the UTC offset was available
    }
    var latitude: Double
    var longitude: Double
    var source: Source

    var summary: String {
        let lat = String(format: "%.2f°%@", abs(latitude), latitude >= 0 ? "N" : "S")
        let lon = String(format: "%.2f°%@", abs(longitude), longitude >= 0 ? "E" : "W")
        switch source {
        case .manual: return "\(lat), \(lon)"
        case .zoneCity(let id): return "\(lat), \(lon) (from time zone \(id))"
        case .offsetGuess: return "\(lat), \(lon) (guessed from the clock offset)"
        }
    }
}

/// Finds a rough location without asking for location permission: every time
/// zone in the system's zoneinfo table carries the coordinates of its
/// reference city. Nothing leaves the machine.
enum Location {
    static let systemZoneinfo = "/usr/share/zoneinfo"

    static func place(for zone: TimeZone, zoneinfo: String = systemZoneinfo) -> Place {
        let table = zoneTable(zoneinfo: zoneinfo)
        if let c = table[zone.identifier] {
            return Place(latitude: c.latitude, longitude: c.longitude, source: .zoneCity(zone.identifier))
        }
        // Older names such as Asia/Calcutta are not in the table, but their
        // rule file is byte-for-byte the file of the zone that replaced them.
        if let data = FileManager.default.contents(atPath: "\(zoneinfo)/\(zone.identifier)") {
            for id in table.keys.sorted() where FileManager.default.contents(atPath: "\(zoneinfo)/\(id)") == data {
                let c = table[id]!
                return Place(latitude: c.latitude, longitude: c.longitude, source: .zoneCity(id))
            }
        }
        // Last resort: the standard-time offset gives the longitude to within a
        // zone's width. The latitude is unknowable; mid-northern is the commonest case.
        let standard = Double(zone.secondsFromGMT()) - zone.daylightSavingTimeOffset()
        return Place(latitude: 30, longitude: max(-180, min(180, standard / 3600 * 15)), source: .offsetGuess)
    }

    /// Zone identifier to coordinates, from `zone.tab`.
    static func zoneTable(zoneinfo: String = systemZoneinfo) -> [String: (latitude: Double, longitude: Double)] {
        guard let text = try? String(contentsOfFile: "\(zoneinfo)/zone.tab", encoding: .utf8) else { return [:] }
        var table = [String: (latitude: Double, longitude: Double)]()
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let cols = line.split(separator: "\t")
            if cols.count >= 3, let c = parseISO6709(String(cols[1])) { table[String(cols[2])] = c }
        }
        return table
    }

    /// "+2232+08822" or "+223200+0882200" to degrees.
    static func parseISO6709(_ s: String) -> (latitude: Double, longitude: Double)? {
        let chars = Array(s)
        guard let split = chars.indices.dropFirst().first(where: { chars[$0] == "+" || chars[$0] == "-" })
        else { return nil }
        func value(_ part: ArraySlice<Character>, degreeDigits: Int) -> Double? {
            let sign: Double = part.first == "-" ? -1 : 1
            let digits = String(part.dropFirst())
            guard digits.count >= degreeDigits + 2, digits.allSatisfy(\.isNumber),
                  let deg = Double(digits.prefix(degreeDigits)),
                  let min = Double(digits.dropFirst(degreeDigits).prefix(2)) else { return nil }
            let sec = Double(digits.dropFirst(degreeDigits + 2)) ?? 0
            return sign * (deg + min / 60 + sec / 3600)
        }
        guard let lat = value(chars[..<split], degreeDigits: 2),
              let lon = value(chars[split...], degreeDigits: 3),
              abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        return (lat, lon)
    }
}
