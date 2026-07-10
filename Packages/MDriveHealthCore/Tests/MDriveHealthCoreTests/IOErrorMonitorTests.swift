/*
 * IOErrorMonitorTests.swift — rolling window + boundary matcher.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import XCTest
@testable import MDriveHealthCore

final class IOErrorMonitorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    private func event(minutesAgo: Double, _ message: String) -> IOErrorEvent {
        IOErrorEvent(date: now.addingTimeInterval(-minutesAgo * 60), message: message)
    }

    // MARK: - Boundary matcher

    func testMentionsExactDeviceAndPartitions() {
        XCTAssertTrue(IOErrorEvent(date: now, message: "I/O error on disk1")
            .mentions("disk1"))
        XCTAssertTrue(IOErrorEvent(date: now, message: "write error disk1s2 failed")
            .mentions("disk1"))
    }

    func testMentionsRejectsLongerDeviceAndSubstrings() {
        // "disk1" must not match "disk10".
        XCTAssertFalse(IOErrorEvent(date: now, message: "I/O error on disk10")
            .mentions("disk1"))
        // nor "rdisk1".
        XCTAssertFalse(IOErrorEvent(date: now, message: "error on rdisk1")
            .mentions("disk1"))
        XCTAssertFalse(IOErrorEvent(date: now, message: "").mentions("disk1"))
        XCTAssertFalse(IOErrorEvent(date: now, message: "disk2 error").mentions(""))
    }

    // MARK: - Scan cadence

    func testFirstScanCoversFullWindow() {
        XCTAssertEqual(IOErrorMonitor.scanMinutes(lastScan: nil, now: now), 24 * 60)
    }

    func testRescanTooSoonIsSkipped() {
        let recent = now.addingTimeInterval(-600) // 10 min ago < 30 min gate
        XCTAssertNil(IOErrorMonitor.scanMinutes(lastScan: recent, now: now))
    }

    func testIncrementalScanCoversGapPlusOverlap() {
        let last = now.addingTimeInterval(-3_600) // 60 min ago
        // 60 min elapsed + 5 min overlap = 65.
        XCTAssertEqual(IOErrorMonitor.scanMinutes(lastScan: last, now: now), 65)
    }

    // MARK: - Merge

    func testMergeDropsExpiredAndDeduplicates() {
        let known = [
            event(minutesAgo: 30, "a"),
            event(minutesAgo: 23 * 60, "b"),
            event(minutesAgo: 25 * 60, "old"), // outside 24h window → dropped
        ]
        let fresh = [
            event(minutesAgo: 30, "a"),        // duplicate of known → not re-added
            event(minutesAgo: 5, "c"),         // new
        ]
        let merged = IOErrorMonitor.merge(known: known, fresh: fresh, now: now)
        XCTAssertEqual(merged.map(\.message).sorted(), ["a", "b", "c"])
    }

    // MARK: - Counts

    func testCountsUseExactDeviceMatch() {
        let events = [
            event(minutesAgo: 1, "I/O error on disk1"),
            event(minutesAgo: 2, "I/O error on disk1s3"),
            event(minutesAgo: 3, "I/O error on disk10"), // must not count for disk1
        ]
        let counts = IOErrorMonitor.counts(events: events, bsdNames: ["disk1", "disk10"])
        XCTAssertEqual(counts["disk1"], 2)
        XCTAssertEqual(counts["disk10"], 1)
    }
}
