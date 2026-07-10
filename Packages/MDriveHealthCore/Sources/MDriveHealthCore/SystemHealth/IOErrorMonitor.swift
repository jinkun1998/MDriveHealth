/*
 * IOErrorMonitor.swift — rolling 24h window of kernel I/O errors.
 * Pure, testable helpers around IOErrorWatcher's one-shot scans: the app
 * owns the cadence, this owns the window/merge/count algorithm.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import Foundation

public enum IOErrorMonitor {
    /// The window kept and reported on.
    public static let window: TimeInterval = 24 * 3_600
    /// Do not rescan more often than this.
    public static let minScanInterval: TimeInterval = 1_800
    /// Overlap added to incremental scans so events near the boundary of the
    /// previous scan cannot slip through the gap.
    public static let scanOverlap: TimeInterval = 300

    /// How many minutes back the next `log show` should cover, or nil when the
    /// last scan is too recent to repeat. First scan (lastScan == nil) covers
    /// the whole window; later ones cover only the elapsed gap plus overlap.
    public static func scanMinutes(lastScan: Date?, now: Date) -> Int? {
        guard let lastScan else { return Int(window / 60) }
        let elapsed = now.timeIntervalSince(lastScan)
        guard elapsed >= minScanInterval else { return nil }
        return Int((elapsed + scanOverlap) / 60)
    }

    /// Merges freshly scanned events into the known set, dropping anything
    /// older than the window and de-duplicating the overlap.
    public static func merge(known: [IOErrorEvent], fresh: [IOErrorEvent],
                             now: Date) -> [IOErrorEvent] {
        let cutoff = now.addingTimeInterval(-window)
        var merged = known.filter { $0.date >= cutoff }
        let seen = Set(merged)
        merged.append(contentsOf: fresh.filter { $0.date >= cutoff && !seen.contains($0) })
        return merged
    }

    /// Per-device error counts using the exact-device matcher (so "disk1"
    /// never absorbs "disk10").
    public static func counts(events: [IOErrorEvent],
                              bsdNames: [String]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for name in bsdNames where !name.isEmpty {
            counts[name] = events.filter { $0.mentions(name) }.count
        }
        return counts
    }
}
