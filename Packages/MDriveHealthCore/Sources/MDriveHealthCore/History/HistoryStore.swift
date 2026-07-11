/*
 * HistoryStore.swift — SQLite-backed time series of drive snapshots.
 * Uses the system libsqlite3 directly; the schema is one flat table.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One recorded point of a drive's history.
public struct HistoryPoint: Sendable, Codable, Hashable {
    public let capturedAt: Date
    public let temperatureC: Int?
    public let healthScore: Int?
    public let rating: String?
    public let lifetimeLeftPercent: Int?
    public let powerOnHours: UInt64?
    public let bytesWritten: UInt64?
    /// ATA attr 5 raw / NVMe media errors — the "growing defects" signal.
    public let defectCount: UInt64?
    /// ATA attr 197 raw (pending sectors); nil for NVMe.
    public let pendingSectors: UInt64?
}

public enum HistoryError: Error, LocalizedError {
    case sqlite(String)

    public var errorDescription: String? {
        if case .sqlite(let message) = self { return "SQLite: \(message)" }
        return nil
    }
}

/// Thread-safe (serialized) append/query store for drive history.
public final class HistoryStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.maclife.mdrivehealth.history")

    /// Default database lives in ~/Library/Application Support/MDriveHealth/.
    public static func defaultDatabaseURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let directory = support.appendingPathComponent("MDriveHealth", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("history.db")
    }

    public init(databaseURL: URL? = nil) throws {
        let url = try databaseURL ?? Self.defaultDatabaseURL()
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            throw HistoryError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        // WAL keeps readers unblocked during inserts; busy_timeout covers the
        // rare second process (CLI) touching the same database.
        try? execute("PRAGMA journal_mode=WAL")
        try? execute("PRAGMA busy_timeout=3000")
        try execute("""
            CREATE TABLE IF NOT EXISTS drive_snapshots (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                drive_key TEXT NOT NULL,
                bsd_name TEXT,
                captured_at REAL NOT NULL,
                temperature_c INTEGER,
                health_score INTEGER,
                rating TEXT,
                lifetime_left INTEGER,
                power_on_hours INTEGER,
                bytes_written INTEGER,
                defect_count INTEGER,
                pending_sectors INTEGER
            );
            CREATE INDEX IF NOT EXISTS idx_snapshots_drive_time
                ON drive_snapshots(drive_key, captured_at);
            CREATE INDEX IF NOT EXISTS idx_snapshots_time
                ON drive_snapshots(captured_at);
            CREATE TABLE IF NOT EXISTS benchmark_results (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                drive_key TEXT NOT NULL,
                bsd_name TEXT,
                volume_name TEXT,
                mount_point TEXT,
                captured_at REAL NOT NULL,
                file_size INTEGER NOT NULL,
                seq_block INTEGER NOT NULL,
                rand_block INTEGER NOT NULL,
                seq_write_bps REAL NOT NULL,
                seq_read_bps REAL NOT NULL,
                rand_write_bps REAL,
                rand_read_bps REAL,
                queue_depth INTEGER NOT NULL DEFAULT 1
            );
            CREATE INDEX IF NOT EXISTS idx_benchmarks_drive_time
                ON benchmark_results(drive_key, captured_at);
            """)
        // Migration for databases created before queue_depth existed; the
        // duplicate-column error on newer databases is expected and ignored.
        try? execute("ALTER TABLE benchmark_results ADD COLUMN queue_depth INTEGER NOT NULL DEFAULT 1")
    }

    deinit {
        sqlite3_close(db)
    }

    /// Stable identity for a drive across reboots/BSD renumbering.
    public static func driveKey(for drive: DriveInfo) -> String {
        if let serial = drive.serialNumber, !serial.isEmpty {
            return "\(drive.model)#\(serial)"
        }
        if let mediaUUID = drive.mediaUUID, !mediaUUID.isEmpty {
            return "\(drive.model)#\(mediaUUID)"
        }
        return "\(drive.model)#\(drive.sizeBytes)"
    }

    public func record(driveKey: String, bsdName: String,
                       reading: DriveReading, health: HealthReport) throws {
        let defects: UInt64? = reading.defectCount
        let pending: UInt64? = reading.pendingSectors

        try queue.sync {
            // Identical consecutive snapshots are skipped (frequent polling
            // otherwise fills the database with duplicates); one heartbeat
            // row still lands every 6 hours so charts show coverage.
            if let last = try latest_locked(driveKey: driveKey),
               reading.capturedAt.timeIntervalSince(last.capturedAt) < 6 * 3_600,
               last.temperatureC == reading.temperatureCelsius,
               last.healthScore == health.score,
               last.rating == health.rating.rawValue,
               last.lifetimeLeftPercent == health.lifetimeLeftPercent,
               last.powerOnHours == reading.powerOnHours,
               last.bytesWritten == reading.bytesWritten,
               last.defectCount == defects,
               last.pendingSectors == pending {
                return
            }
            let sql = """
                INSERT INTO drive_snapshots
                (drive_key, bsd_name, captured_at, temperature_c, health_score,
                 rating, lifetime_left, power_on_hours, bytes_written,
                 defect_count, pending_sectors)
                VALUES (?,?,?,?,?,?,?,?,?,?,?)
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw HistoryError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, driveKey, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, bsdName, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(statement, 3, reading.capturedAt.timeIntervalSince1970)
            bindOptionalInt(statement, 4, reading.temperatureCelsius.map(Int64.init))
            sqlite3_bind_int64(statement, 5, Int64(health.score))
            sqlite3_bind_text(statement, 6, health.rating.rawValue, -1, SQLITE_TRANSIENT)
            bindOptionalInt(statement, 7, health.lifetimeLeftPercent.map(Int64.init))
            bindOptionalInt(statement, 8, reading.powerOnHours.map { Int64(clamping: $0) })
            bindOptionalInt(statement, 9, reading.bytesWritten.map { Int64(clamping: $0) })
            bindOptionalInt(statement, 10, defects.map { Int64(clamping: $0) })
            bindOptionalInt(statement, 11, pending.map { Int64(clamping: $0) })

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw HistoryError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    public func history(driveKey: String, since: Date) throws -> [HistoryPoint] {
        try queue.sync {
            let sql = """
                SELECT captured_at, temperature_c, health_score, rating,
                       lifetime_left, power_on_hours, bytes_written,
                       defect_count, pending_sectors
                FROM drive_snapshots
                WHERE drive_key = ? AND captured_at >= ?
                ORDER BY captured_at ASC
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw HistoryError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, driveKey, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(statement, 2, since.timeIntervalSince1970)

            var points: [HistoryPoint] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                points.append(point(from: statement))
            }
            return points
        }
    }

    /// Latest recorded point in each time bucket. Useful for charts: it keeps
    /// long ranges responsive without changing the underlying raw history.
    public func history(driveKey: String, since: Date,
                        bucketInterval: TimeInterval) throws -> [HistoryPoint] {
        guard bucketInterval > 1 else { return try history(driveKey: driveKey, since: since) }
        return try queue.sync {
            let sql = """
                SELECT captured_at, temperature_c, health_score, rating,
                       lifetime_left, power_on_hours, bytes_written,
                       defect_count, pending_sectors
                FROM drive_snapshots
                WHERE id IN (
                    SELECT MAX(id)
                    FROM drive_snapshots
                    WHERE drive_key = ? AND captured_at >= ?
                    GROUP BY CAST(captured_at / ? AS INTEGER)
                )
                ORDER BY captured_at ASC
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw HistoryError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, driveKey, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(statement, 2, since.timeIntervalSince1970)
            sqlite3_bind_double(statement, 3, bucketInterval)

            var points: [HistoryPoint] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                points.append(point(from: statement))
            }
            return points
        }
    }

    /// Latest recorded point per drive key (for change detection in monitoring).
    public func latest(driveKey: String) throws -> HistoryPoint? {
        try queue.sync { try latest_locked(driveKey: driveKey) }
    }

    private func latest_locked(driveKey: String) throws -> HistoryPoint? {
        let sql = """
            SELECT captured_at, temperature_c, health_score, rating,
                   lifetime_left, power_on_hours, bytes_written,
                   defect_count, pending_sectors
            FROM drive_snapshots
            WHERE drive_key = ?
            ORDER BY captured_at DESC
            LIMIT 1
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw HistoryError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, driveKey, -1, SQLITE_TRANSIENT)
        return sqlite3_step(statement) == SQLITE_ROW ? point(from: statement) : nil
    }

    public func pruneOlderThan(_ date: Date) throws {
        try queue.sync {
            for table in ["drive_snapshots", "benchmark_results"] {
                let sql = "DELETE FROM \(table) WHERE captured_at < ?"
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                    throw HistoryError.sqlite(String(cString: sqlite3_errmsg(db)))
                }
                defer { sqlite3_finalize(statement) }
                sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw HistoryError.sqlite(String(cString: sqlite3_errmsg(db)))
                }
            }
        }
    }

    // MARK: - Internals

    /// The benchmark extension in HistoryStore+Benchmark.swift reuses the
    /// serialized queue and the sqlite handle through these.
    var database: OpaquePointer? { db }
    var serialQueue: DispatchQueue { queue }

    func bindOptionalInt(_ statement: OpaquePointer?, _ index: Int32, _ value: Int64?) {
        if let value {
            sqlite3_bind_int64(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func columnOptionalInt(_ statement: OpaquePointer?, _ index: Int32) -> Int64? {
        sqlite3_column_type(statement, index) == SQLITE_NULL
            ? nil : sqlite3_column_int64(statement, index)
    }

    private func point(from statement: OpaquePointer?) -> HistoryPoint {
        HistoryPoint(
            capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
            temperatureC: columnOptionalInt(statement, 1).map(Int.init),
            healthScore: columnOptionalInt(statement, 2).map(Int.init),
            rating: sqlite3_column_text(statement, 3).map { String(cString: $0) },
            lifetimeLeftPercent: columnOptionalInt(statement, 4).map(Int.init),
            powerOnHours: columnOptionalInt(statement, 5).map { UInt64(clamping: $0) },
            bytesWritten: columnOptionalInt(statement, 6).map { UInt64(clamping: $0) },
            defectCount: columnOptionalInt(statement, 7).map { UInt64(clamping: $0) },
            pendingSectors: columnOptionalInt(statement, 8).map { UInt64(clamping: $0) }
        )
    }

    private func execute(_ sql: String) throws {
        try queue.sync { try execute_locked(sql) }
    }

    private func execute_locked(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorMessage)
            throw HistoryError.sqlite(message)
        }
    }
}
