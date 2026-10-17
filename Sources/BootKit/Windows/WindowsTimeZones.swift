import Foundation

/// IANA → Windows time zone names (subset of Unicode CLDR windowsZones.xml, "001" territories
/// plus common cities), used to duplicate the Mac's time zone into the Windows answer file.
public enum WindowsTimeZones {
    static let map: [String: String] = [
        "Etc/GMT+12": "Dateline Standard Time", "Pacific/Pago_Pago": "UTC-11", "Pacific/Honolulu": "Hawaiian Standard Time",
        "America/Anchorage": "Alaskan Standard Time", "America/Tijuana": "Pacific Standard Time (Mexico)",
        "America/Los_Angeles": "Pacific Standard Time", "America/Vancouver": "Pacific Standard Time",
        "America/Phoenix": "US Mountain Standard Time", "America/Denver": "Mountain Standard Time", "America/Edmonton": "Mountain Standard Time",
        "America/Chihuahua": "Mountain Standard Time (Mexico)", "America/Chicago": "Central Standard Time", "America/Winnipeg": "Central Standard Time",
        "America/Mexico_City": "Central Standard Time (Mexico)", "America/Regina": "Canada Central Standard Time",
        "America/Guatemala": "Central America Standard Time", "America/Bogota": "SA Pacific Standard Time", "America/Lima": "SA Pacific Standard Time",
        "America/New_York": "Eastern Standard Time", "America/Toronto": "Eastern Standard Time", "America/Detroit": "Eastern Standard Time",
        "America/Indiana/Indianapolis": "US Eastern Standard Time", "America/Havana": "Cuba Standard Time", "America/Caracas": "Venezuela Standard Time",
        "America/Halifax": "Atlantic Standard Time", "America/La_Paz": "SA Western Standard Time", "America/Santiago": "Pacific SA Standard Time",
        "America/St_Johns": "Newfoundland Standard Time", "America/Sao_Paulo": "E. South America Standard Time",
        "America/Argentina/Buenos_Aires": "Argentina Standard Time", "America/Buenos_Aires": "Argentina Standard Time",
        "America/Cayenne": "SA Eastern Standard Time", "America/Montevideo": "Montevideo Standard Time", "America/Nuuk": "Greenland Standard Time",
        "America/Godthab": "Greenland Standard Time", "Atlantic/South_Georgia": "UTC-02", "Atlantic/Azores": "Azores Standard Time",
        "Atlantic/Cape_Verde": "Cape Verde Standard Time", "Etc/UTC": "UTC", "UTC": "UTC", "Etc/GMT": "UTC",
        "Europe/London": "GMT Standard Time", "Europe/Dublin": "GMT Standard Time", "Europe/Lisbon": "GMT Standard Time",
        "Atlantic/Reykjavik": "Greenwich Standard Time", "Africa/Casablanca": "Morocco Standard Time",
        "Europe/Berlin": "W. Europe Standard Time", "Europe/Amsterdam": "W. Europe Standard Time", "Europe/Rome": "W. Europe Standard Time",
        "Europe/Stockholm": "W. Europe Standard Time", "Europe/Vienna": "W. Europe Standard Time", "Europe/Zurich": "W. Europe Standard Time",
        "Europe/Oslo": "W. Europe Standard Time", "Europe/Budapest": "Central Europe Standard Time", "Europe/Prague": "Central Europe Standard Time",
        "Europe/Belgrade": "Central Europe Standard Time", "Europe/Paris": "Romance Standard Time", "Europe/Brussels": "Romance Standard Time",
        "Europe/Madrid": "Romance Standard Time", "Europe/Copenhagen": "Romance Standard Time", "Europe/Warsaw": "Central European Standard Time",
        "Europe/Zagreb": "Central European Standard Time", "Africa/Lagos": "W. Central Africa Standard Time",
        "Europe/Athens": "GTB Standard Time", "Europe/Bucharest": "GTB Standard Time", "Asia/Beirut": "Middle East Standard Time",
        "Africa/Cairo": "Egypt Standard Time", "Europe/Chisinau": "E. Europe Standard Time", "Asia/Damascus": "Syria Standard Time",
        "Africa/Johannesburg": "South Africa Standard Time", "Europe/Kiev": "FLE Standard Time", "Europe/Kyiv": "FLE Standard Time",
        "Europe/Helsinki": "FLE Standard Time", "Europe/Riga": "FLE Standard Time", "Europe/Sofia": "FLE Standard Time",
        "Europe/Tallinn": "FLE Standard Time", "Europe/Vilnius": "FLE Standard Time", "Asia/Jerusalem": "Israel Standard Time",
        "Europe/Kaliningrad": "Kaliningrad Standard Time", "Africa/Tripoli": "Libya Standard Time", "Asia/Baghdad": "Arabic Standard Time",
        "Europe/Istanbul": "Turkey Standard Time", "Asia/Riyadh": "Arab Standard Time", "Asia/Kuwait": "Arab Standard Time",
        "Europe/Minsk": "Belarus Standard Time", "Europe/Moscow": "Russian Standard Time", "Africa/Nairobi": "E. Africa Standard Time",
        "Asia/Tehran": "Iran Standard Time", "Asia/Dubai": "Arabian Standard Time", "Europe/Samara": "Russia Time Zone 3",
        "Asia/Baku": "Azerbaijan Standard Time", "Indian/Mauritius": "Mauritius Standard Time", "Asia/Tbilisi": "Georgian Standard Time",
        "Asia/Yerevan": "Caucasus Standard Time", "Asia/Kabul": "Afghanistan Standard Time", "Asia/Tashkent": "West Asia Standard Time",
        "Asia/Yekaterinburg": "Ekaterinburg Standard Time", "Asia/Karachi": "Pakistan Standard Time", "Asia/Kolkata": "India Standard Time",
        "Asia/Calcutta": "India Standard Time", "Asia/Colombo": "Sri Lanka Standard Time", "Asia/Kathmandu": "Nepal Standard Time",
        "Asia/Almaty": "Central Asia Standard Time", "Asia/Dhaka": "Bangladesh Standard Time", "Asia/Omsk": "Omsk Standard Time",
        "Asia/Yangon": "Myanmar Standard Time", "Asia/Bangkok": "SE Asia Standard Time", "Asia/Jakarta": "SE Asia Standard Time",
        "Asia/Ho_Chi_Minh": "SE Asia Standard Time", "Asia/Novosibirsk": "N. Central Asia Standard Time",
        "Asia/Krasnoyarsk": "North Asia Standard Time", "Asia/Shanghai": "China Standard Time", "Asia/Hong_Kong": "China Standard Time",
        "Asia/Irkutsk": "North Asia East Standard Time", "Asia/Singapore": "Singapore Standard Time", "Asia/Kuala_Lumpur": "Singapore Standard Time",
        "Asia/Manila": "Singapore Standard Time", "Australia/Perth": "W. Australia Standard Time", "Asia/Taipei": "Taipei Standard Time",
        "Asia/Ulaanbaatar": "Ulaanbaatar Standard Time", "Asia/Tokyo": "Tokyo Standard Time", "Asia/Seoul": "Korea Standard Time",
        "Asia/Pyongyang": "North Korea Standard Time", "Asia/Yakutsk": "Yakutsk Standard Time", "Australia/Adelaide": "Cen. Australia Standard Time",
        "Australia/Darwin": "AUS Central Standard Time", "Australia/Brisbane": "E. Australia Standard Time",
        "Australia/Sydney": "AUS Eastern Standard Time", "Australia/Melbourne": "AUS Eastern Standard Time",
        "Pacific/Port_Moresby": "West Pacific Standard Time", "Australia/Hobart": "Tasmania Standard Time",
        "Asia/Vladivostok": "Vladivostok Standard Time", "Pacific/Guadalcanal": "Central Pacific Standard Time",
        "Asia/Magadan": "Magadan Standard Time", "Pacific/Auckland": "New Zealand Standard Time", "Pacific/Fiji": "Fiji Standard Time",
        "Asia/Kamchatka": "Russia Time Zone 11", "Pacific/Tongatapu": "Tonga Standard Time", "Pacific/Apia": "Samoa Standard Time",
        "Pacific/Kiritimati": "Line Islands Standard Time",
    ]

    public static func windowsName(for iana: String) -> String? {
        if let m = map[iana] { return m }
        // Fall back to a zone with the same current UTC offset.
        guard let tz = TimeZone(identifier: iana) else { return nil }
        let offset = tz.secondsFromGMT()
        return map.first { TimeZone(identifier: $0.key)?.secondsFromGMT() == offset }?.value
    }
}
