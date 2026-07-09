/*
 * ATARawDecoder.swift — decodes 6-byte ATA attribute raw values per the
 * drivedb format names (raw48, tempminmax, minutes, ...).
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import Foundation

public enum ATARawDecoder {
    /// Decodes the 6 raw bytes (little-endian, `raw[0]` = LSB) of an ATA SMART
    /// attribute. Returns the primary numeric value (used by trend/scoring
    /// logic) and a human-readable rendering.
    public static func decode(raw: [UInt8], format: String) -> (value: UInt64, display: String) {
        precondition(raw.count >= 6)
        let le48 = le(raw, 0, 6)

        switch format {
        case "raw8":
            return (le48, (0..<6).reversed().map { String(raw[$0]) }.joined(separator: " "))
        case "raw16":
            let words = [le(raw, 0, 2), le(raw, 2, 2), le(raw, 4, 2)]
            let display = words[1] == 0 && words[2] == 0
                ? String(words[0])
                : "\(words[0]) \(words[1]) \(words[2])"
            return (words[0], display)
        case "raw16(raw16)":
            let main = le(raw, 0, 2)
            let hi = (le(raw, 2, 2), le(raw, 4, 2))
            return (main, hi.0 == 0 && hi.1 == 0 ? String(main) : "\(main) (\(hi.0) \(hi.1))")
        case "raw16(avg16)":
            let main = le(raw, 0, 2)
            let avg = le(raw, 2, 2)
            return (main, avg > 0 ? "\(main) (Average \(avg))" : String(main))
        case "raw24(raw8)":
            let main = le(raw, 0, 3)
            return (main, "\(main) (\(raw[5]) \(raw[4]) \(raw[3]))")
        case "raw24/raw24":
            let lo = le(raw, 0, 3), hi = le(raw, 3, 3)
            return (lo, "\(lo)/\(hi)")
        case "raw24/raw32", "loadunload":
            // High 16 bits = count of interest, low 32 bits = companion counter.
            let hi = le(raw, 4, 2), lo = le(raw, 0, 4)
            return (hi, "\(hi)/\(lo)")
        case "raw56":
            return (le48, String(le48))
        case "raw64":
            return (le48, String(le48))
        case "hex48", "hex56", "hex64":
            return (le48, String(format: "0x%llx", le48))
        case "seconds", "sec2hour":
            let hours = le48 / 3600, rem = le48 % 3600
            return (hours, "\(hours)h+\(String(format: "%02d", rem / 60))m+\(String(format: "%02d", rem % 60))s")
        case "minutes", "min2hour":
            return (le48 / 60, "\(le48 / 60)h+\(String(format: "%02d", le48 % 60))m")
        case "halfminutes", "halfmin2hour":
            let minutes = le48 / 2
            return (minutes / 60, "\(minutes / 60)h+\(String(format: "%02d", minutes % 60))m")
        case "msec24hour32":
            // Low 32 bits = hours, high 24 bits = milliseconds within the hour.
            let hours = le(raw, 0, 4)
            let minutes = le(raw, 4, 2) / 60000
            return (hours, "\(hours)h+\(String(format: "%02d", minutes))m")
        case "tempminmax":
            let current = UInt64(raw[0])
            let low = raw[2], high = raw[4]
            if high > 0, low <= high, current >= UInt64(low), current <= UInt64(high) {
                return (current, "\(current) (Min/Max \(low)/\(high))")
            }
            return (current, String(current))
        case "temp10x", "10xCelsius":
            let tenths = le(raw, 0, 2)
            return (tenths / 10, String(format: "%.1f", Double(tenths) / 10))
        default:
            // raw48 and vendor-specific aliases (increasing, writeerrorcount, ...)
            return (le48, String(le48))
        }
    }

    private static func le(_ bytes: [UInt8], _ offset: Int, _ count: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in (0..<count).reversed() {
            value = (value << 8) | UInt64(bytes[offset + i])
        }
        return value
    }
}
