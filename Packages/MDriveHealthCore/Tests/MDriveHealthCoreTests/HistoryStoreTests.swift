/*
 * HistoryStoreTests.swift
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import XCTest
@testable import MDriveHealthCore

final class HistoryStoreTests: XCTestCase {
    private var store: HistoryStore!
    private var databaseURL: URL!

    override func setUpWithError() throws {
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdrivehealth-test-\(UUID().uuidString).db")
        store = try HistoryStore(databaseURL: databaseURL)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: databaseURL)
    }

    private func sampleReading(capturedAt: Date, mediaErrors: UInt64 = 0) -> DriveReading {
        .nvme(NVMeReading(
            controller: NVMeControllerInfo(
                model: "T", serialNumber: "S", firmwareRevision: "F", ieeeOUI: "0",
                controllerID: 0, specVersion: nil, totalCapacityBytes: 0,
                unallocatedCapacityBytes: 0, warningTempKelvin: 0,
                criticalTempKelvin: 0, namespaceCount: 1),
            smart: NVMeSMARTSnapshot(
                capturedAt: capturedAt, criticalWarning: [], temperatureKelvin: 310,
                availableSpare: 100, availableSpareThreshold: 10, percentageUsed: 5,
                dataUnitsRead: 1, dataUnitsWritten: 2, hostReadCommands: 0,
                hostWriteCommands: 0, controllerBusyTimeMinutes: 0, powerCycles: 1,
                powerOnHours: 42, unsafeShutdowns: 0, mediaErrors: mediaErrors,
                errorLogEntries: 0, warningTempTimeMinutes: 0,
                criticalTempTimeMinutes: 0, temperatureSensorsKelvin: [])))
    }

    func testRecordAndQueryRoundTrip() throws {
        let now = Date()
        let reading = sampleReading(capturedAt: now)
        try store.record(driveKey: "TEST#1", bsdName: "disk0",
                         reading: reading, health: reading.evaluateHealth())

        let points = try store.history(driveKey: "TEST#1",
                                       since: now.addingTimeInterval(-60))
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points[0].temperatureC, 37)
        XCTAssertEqual(points[0].healthScore, 100)
        XCTAssertEqual(points[0].rating, "good")
        XCTAssertEqual(points[0].lifetimeLeftPercent, 95)
        XCTAssertEqual(points[0].powerOnHours, 42)
        XCTAssertEqual(points[0].defectCount, 0)
        XCTAssertNil(points[0].pendingSectors, "NVMe has no pending sectors")
    }

    func testSinceFilterAndOrdering() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for offset in [0.0, 100, 200, 300] {
            let reading = sampleReading(capturedAt: base.addingTimeInterval(offset),
                                        mediaErrors: UInt64(offset))
            try store.record(driveKey: "TEST#1", bsdName: "disk0",
                             reading: reading, health: reading.evaluateHealth())
        }
        let points = try store.history(driveKey: "TEST#1",
                                       since: base.addingTimeInterval(150))
        XCTAssertEqual(points.count, 2)
        XCTAssertTrue(points[0].capturedAt < points[1].capturedAt)
    }

    func testIdenticalConsecutiveSnapshotsAreDeduplicated() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for offset in [0.0, 300, 600] {
            let reading = sampleReading(capturedAt: base.addingTimeInterval(offset))
            try store.record(driveKey: "TEST#1", bsdName: "disk0",
                             reading: reading, health: reading.evaluateHealth())
        }
        XCTAssertEqual(try store.history(driveKey: "TEST#1", since: .distantPast).count, 1,
                       "identical back-to-back snapshots should collapse into one row")

        let changed = sampleReading(capturedAt: base.addingTimeInterval(900),
                                    mediaErrors: 3)
        try store.record(driveKey: "TEST#1", bsdName: "disk0",
                         reading: changed, health: changed.evaluateHealth())
        XCTAssertEqual(try store.history(driveKey: "TEST#1", since: .distantPast).count, 2,
                       "a changed value must still be recorded")
    }

    func testIdenticalSnapshotStillRecordedAsHeartbeatAfterSixHours() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let first = sampleReading(capturedAt: base)
        try store.record(driveKey: "TEST#1", bsdName: "disk0",
                         reading: first, health: first.evaluateHealth())
        let later = sampleReading(capturedAt: base.addingTimeInterval(7 * 3_600))
        try store.record(driveKey: "TEST#1", bsdName: "disk0",
                         reading: later, health: later.evaluateHealth())
        XCTAssertEqual(try store.history(driveKey: "TEST#1", since: .distantPast).count, 2)
    }

    func testLatestUsesMostRecentPoint() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for offset in [0.0, 100, 200] {
            let reading = sampleReading(capturedAt: base.addingTimeInterval(offset),
                                        mediaErrors: UInt64(offset))
            try store.record(driveKey: "TEST#1", bsdName: "disk0",
                             reading: reading, health: reading.evaluateHealth())
        }

        let latest = try store.latest(driveKey: "TEST#1")
        XCTAssertEqual(latest?.capturedAt, base.addingTimeInterval(200))
        XCTAssertEqual(latest?.defectCount, 200)
        XCTAssertNil(try store.latest(driveKey: "missing"))
    }

    func testBucketedHistoryKeepsOnePointPerBucket() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for offset in [0.0, 10, 20, 70, 80] {
            let reading = sampleReading(capturedAt: base.addingTimeInterval(offset),
                                        mediaErrors: UInt64(offset))
            try store.record(driveKey: "TEST#1", bsdName: "disk0",
                             reading: reading, health: reading.evaluateHealth())
        }

        let points = try store.history(driveKey: "TEST#1", since: base,
                                       bucketInterval: 60)
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points.map(\.defectCount), [20, 80])
    }

    func testKeysAreIsolatedAndPruneWorks() throws {
        let now = Date()
        let old = sampleReading(capturedAt: now.addingTimeInterval(-400 * 86_400))
        let fresh = sampleReading(capturedAt: now)
        try store.record(driveKey: "A", bsdName: "disk0", reading: old,
                         health: old.evaluateHealth())
        try store.record(driveKey: "B", bsdName: "disk1", reading: fresh,
                         health: fresh.evaluateHealth())

        XCTAssertEqual(try store.history(driveKey: "A", since: .distantPast).count, 1)
        try store.pruneOlderThan(now.addingTimeInterval(-365 * 86_400))
        XCTAssertEqual(try store.history(driveKey: "A", since: .distantPast).count, 0,
                       "year-old point should be pruned")
        XCTAssertEqual(try store.history(driveKey: "B", since: .distantPast).count, 1)
    }
}
