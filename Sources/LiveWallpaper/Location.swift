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
        // Older names that macOS still offers but the table has dropped.
        if let current = legacyNames[zone.identifier], let c = table[current] {
            return Place(latitude: c.latitude, longitude: c.longitude, source: .zoneCity(current))
        }
        // Any other name missing from the table: its rule file is byte-for-byte
        // the file of the zone that replaced it.
        // Several zones can share one rule file (Reykjavik and Abidjan, Auckland
        // and McMurdo), so among the matches prefer an inhabited zone whose city
        // lies nearest the longitude the clock offset implies.
        let standard = Double(zone.secondsFromGMT()) - zone.daylightSavingTimeOffset()
        let offsetLongitude = max(-180, min(180, standard / 240))
        if let data = FileManager.default.contents(atPath: "\(zoneinfo)/\(zone.identifier)") {
            var matches = table.keys.filter { FileManager.default.contents(atPath: "\(zoneinfo)/\($0)") == data }
            let inhabited = matches.filter { !$0.hasPrefix("Antarctica/") }
            if !inhabited.isEmpty { matches = inhabited }
            let region = zone.identifier.split(separator: "/").first.map(String.init) ?? ""
            let sameRegion = matches.filter { $0.hasPrefix(region + "/") }
            if !sameRegion.isEmpty { matches = sameRegion }
            if let id = matches.sorted().min(by: {
                abs(table[$0]!.longitude - offsetLongitude) < abs(table[$1]!.longitude - offsetLongitude)
            }), let c = table[id] {
                return Place(latitude: c.latitude, longitude: c.longitude, source: .zoneCity(id))
            }
        }
        // Last resort: the standard-time offset gives the longitude to within a
        // zone's width. The latitude is unknowable; mid-northern is the commonest case.
        return Place(latitude: 30, longitude: offsetLongitude, source: .offsetGuess)
    }

    /// The time-zone names macOS lists that `zone.tab` no longer carries, and their successors.
    static let legacyNames: [String: String] = [
        "America/Godthab": "America/Nuuk", "America/Montreal": "America/Toronto",
        "America/Nipigon": "America/Toronto", "America/Pangnirtung": "America/Iqaluit",
        "America/Rainy_River": "America/Winnipeg", "America/Santa_Isabel": "America/Tijuana",
        "America/Shiprock": "America/Denver", "America/Thunder_Bay": "America/Toronto",
        "America/Yellowknife": "America/Edmonton", "Antarctica/South_Pole": "Antarctica/McMurdo",
        "Asia/Calcutta": "Asia/Kolkata", "Asia/Choibalsan": "Asia/Ulaanbaatar",
        "Asia/Chongqing": "Asia/Shanghai", "Asia/Harbin": "Asia/Shanghai", "Asia/Kashgar": "Asia/Urumqi",
        "Asia/Katmandu": "Asia/Kathmandu", "Asia/Rangoon": "Asia/Yangon", "Australia/Currie": "Australia/Hobart",
        "Europe/Kiev": "Europe/Kyiv", "Europe/Uzhgorod": "Europe/Kyiv", "Europe/Zaporozhye": "Europe/Kyiv",
        "Pacific/Enderbury": "Pacific/Kanton", "Pacific/Johnston": "Pacific/Honolulu",
        "Pacific/Ponape": "Pacific/Pohnpei", "Pacific/Truk": "Pacific/Chuuk",
    ]

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
