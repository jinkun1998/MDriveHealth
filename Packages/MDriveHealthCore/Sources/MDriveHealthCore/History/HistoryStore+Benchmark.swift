/*
 * HistoryStore+Benchmark.swift — persistence for disk-speed benchmark runs.
 * Reuses HistoryStore's serialized queue and sqlite handle; same prepared-
 * statement style as the drive-snapshot storage.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

extension HistoryStore {
    /// Every run is an explicit user action, so this always inserts.
    public func record(benchmark result: BenchmarkResult, driveKey: String) throws {
        try serialQueue.sync {
            let sql = """
                INSERT INTO benchmark_results
                (drive_key, bsd_name, volume_name, mount_point, captured_at,
                 file_size, seq_block, rand_block, seq_write_bps, seq_read_bps,
                 rand_write_bps, rand_read_bps, queue_depth)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                throw HistoryError.sqlite(String(cString: sqlite3_errmsg(database)))
            }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, driveKey, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, result.volumeBSDName, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 3, result.volumeName, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 4, result.mountPoint, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(statement, 5, result.capturedAt.timeIntervalSince1970)
            sqlite3_bind_int64(statement, 6, Int64(clamping: result.fileSizeBytes))
            sqlite3_bind_int64(statement, 7, Int64(result.sequentialBlockBytes))
            sqlite3_bind_int64(statement, 8, Int64(result.randomBlockBytes))
            sqlite3_bind_double(statement, 9, result.sequentialWriteBytesPerSec)
            sqlite3_bind_double(statement, 10, result.sequentialReadBytesPerSec)
            bindOptionalDouble(statement, 11, result.randomWriteBytesPerSec)
            bindOptionalDouble(statement, 12, result.randomReadBytesPerSec)
            sqlite3_bind_int64(statement, 13, Int64(result.queueDepth))

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw HistoryError.sqlite(String(cString: sqlite3_errmsg(database)))
            }
        }
    }

    public func latestBenchmark(driveKey: String) throws -> BenchmarkResult? {
        try serialQueue.sync {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, Self.benchmarkSelect
                    + " WHERE drive_key = ? ORDER BY captured_at DESC LIMIT 1",
                    -1, &statement, nil) == SQLITE_OK else {
                throw HistoryError.sqlite(String(cString: sqlite3_errmsg(database)))
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, driveKey, -1, SQLITE_TRANSIENT)
            return sqlite3_step(statement) == SQLITE_ROW ? benchmarkResult(from: statement) : nil
        }
    }

    /// Ascending by captured_at, like history(driveKey:since:).
    public func benchmarks(driveKey: String, since: Date) throws -> [BenchmarkResult] {
        try serialQueue.sync {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, Self.benchmarkSelect
                    + " WHERE drive_key = ? AND captured_at >= ? ORDER BY captured_at ASC",
                    -1, &statement, nil) == SQLITE_OK else {
                throw HistoryError.sqlite(String(cString: sqlite3_errmsg(database)))
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, driveKey, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(statement, 2, since.timeIntervalSince1970)

            var results: [BenchmarkResult] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                results.append(benchmarkResult(from: statement))
            }
            return results
        }
    }

    // MARK: - Internals

    private static let benchmarkSelect = """
        SELECT bsd_name, volume_name, mount_point, captured_at, file_size,
               seq_block, rand_block, seq_write_bps, seq_read_bps,
               rand_write_bps, rand_read_bps, queue_depth
        FROM benchmark_results
        """

    private func benchmarkResult(from statement: OpaquePointer?) -> BenchmarkResult {
        func text(_ i: Int32) -> String {
            sqlite3_column_text(statement, i).map { String(cString: $0) } ?? ""
        }
        return BenchmarkResult(
            capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
            volumeBSDName: text(0), volumeName: text(1), mountPoint: text(2),
            fileSizeBytes: UInt64(clamping: sqlite3_column_int64(statement, 4)),
            sequentialBlockBytes: Int(sqlite3_column_int64(statement, 5)),
            randomBlockBytes: Int(sqlite3_column_int64(statement, 6)),
            queueDepth: max(1, Int(sqlite3_column_int64(statement, 11))),
            sequentialWriteBytesPerSec: sqlite3_column_double(statement, 7),
            sequentialReadBytesPerSec: sqlite3_column_double(statement, 8),
            randomWriteBytesPerSec: columnOptionalDouble(statement, 9),
            randomReadBytesPerSec: columnOptionalDouble(statement, 10))
    }

    private func bindOptionalDouble(_ statement: OpaquePointer?, _ index: Int32, _ value: Double?) {
        if let value {
            sqlite3_bind_double(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func columnOptionalDouble(_ statement: OpaquePointer?, _ index: Int32) -> Double? {
        sqlite3_column_type(statement, index) == SQLITE_NULL
            ? nil : sqlite3_column_double(statement, index)
    }
}
