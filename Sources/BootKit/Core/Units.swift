import Foundation

public enum Units {
    public static let KB: UInt64 = 1024
    public static let MB: UInt64 = 1024 * 1024
    public static let GB: UInt64 = 1024 * 1024 * 1024
    public static let TB: UInt64 = 1024 * 1024 * 1024 * 1024

    /// Human readable size. `decimal` uses 1000-based units like Finder does.
    public static func human(_ bytes: UInt64, decimal: Bool = false) -> String {
        let base: Double = decimal ? 1000 : 1024
        let units = ["bytes", "KB", "MB", "GB", "TB", "PB"]
        var value = Double(bytes)
        var i = 0
        while value >= base && i < units.count - 1 {
            value /= base
            i += 1
        }
        if i == 0 { return "\(bytes) bytes" }
        let fmt = value >= 100 ? "%.0f %@" : (value >= 10 ? "%.1f %@" : "%.2f %@")
        return String(format: fmt, value, units[i])
    }

    /// Rufus style "drive size" label, e.g. "16 GB" for a 15.6 GB stick.
    public static func driveSizeLabel(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 1 {
            let nominal = [1.0, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1000, 2000, 4000, 8000, 16000]
            for n in nominal where gb <= n && gb >= n * 0.85 {
                return n >= 1000 ? "\(Int(n / 1000)) TB" : "\(Int(n)) GB"
            }
            return String(format: "%.1f GB", gb)
        }
        return human(bytes, decimal: true)
    }

    public static func rate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return "—" }
        return human(UInt64(bytesPerSecond)) + "/s"
    }

    public static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let s = Int(seconds.rounded())
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    @inline(__always) public static func alignUp(_ v: UInt64, _ a: UInt64) -> UInt64 {
        guard a > 0 else { return v }
        return (v + a - 1) / a * a
    }

    @inline(__always) public static func alignDown(_ v: UInt64, _ a: UInt64) -> UInt64 {
        guard a > 0 else { return v }
        return v / a * a
    }
}
