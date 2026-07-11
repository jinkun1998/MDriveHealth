/*
 * BenchmarkModels.swift — configuration, progress, and result types for the
 * file-based disk speed benchmark. Localized strings use the package catalog
 * (vi source, en) via bundle: .module, mirroring HealthEvaluator.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import Foundation

/// How the benchmark is run. The UI offers presets; tests may pass tiny sizes.
public struct BenchmarkConfig: Sendable, Codable, Hashable {
    /// Total bytes written then read by the sequential phases.
    public var fileSizeBytes: UInt64
    /// Transfer size of each sequential read/write. QD1 single-threaded, so
    /// this must be large enough to amortize per-op syscall + device latency.
    public var sequentialBlockBytes: Int
    /// Random-access transfer size (the classic 4 KiB IOPS measurement).
    public var randomBlockBytes: Int
    public var includeRandomPhases: Bool
    /// Time budget per random direction (write, then read).
    public var randomPhaseSeconds: TimeInterval

    public init(fileSizeBytes: UInt64 = BenchmarkConfig.defaultFileSize,
                sequentialBlockBytes: Int = 4 * 1_048_576,
                randomBlockBytes: Int = 4096,
                includeRandomPhases: Bool = true,
                randomPhaseSeconds: TimeInterval = 8) {
        self.fileSizeBytes = fileSizeBytes
        self.sequentialBlockBytes = sequentialBlockBytes
        self.randomBlockBytes = randomBlockBytes
        self.includeRandomPhases = includeRandomPhases
        self.randomPhaseSeconds = randomPhaseSeconds
    }

    public static let defaultFileSize: UInt64 = 1 << 30            // 1 GiB
    /// 512 MiB / 1 / 2 / 5 GiB — all exact multiples of 8 MiB, so no unaligned
    /// tail block ever exists for any supported sequential block size.
    public static let presetFileSizes: [UInt64] = [1 << 29, 1 << 30, 1 << 31, 5 << 30]
    /// Free space required beyond the test file itself.
    public static let freeSpaceMarginBytes: UInt64 = 512 << 20
    /// F_NOCACHE requires 4 KiB alignment of buffer, offset, and length.
    public static let pageSize = 4096

    public var requiredFreeBytes: UInt64 { fileSizeBytes + Self.freeSpaceMarginBytes }

    /// Enforces the invariants F_NOCACHE and the phase loops depend on:
    /// both block sizes must be positive multiples of 4 KiB (an unaligned
    /// F_NOCACHE request silently reverts to cached I/O and measures RAM), the
    /// sequential block must be 4 KiB…8 MiB, and the file must divide evenly
    /// into sequential blocks (no unaligned tail).
    public func validate() throws {
        let page = Self.pageSize
        guard sequentialBlockBytes > 0, sequentialBlockBytes % page == 0 else {
            throw BenchmarkError.invalidConfiguration(
                "sequentialBlockBytes must be a positive multiple of \(page)")
        }
        guard sequentialBlockBytes >= page, sequentialBlockBytes <= 8 * 1_048_576 else {
            throw BenchmarkError.invalidConfiguration(
                "sequentialBlockBytes must be between 4 KiB and 8 MiB")
        }
        guard randomBlockBytes > 0, randomBlockBytes % page == 0 else {
            throw BenchmarkError.invalidConfiguration(
                "randomBlockBytes must be a positive multiple of \(page)")
        }
        // The engine's I/O buffers are sized to sequentialBlockBytes; a larger
        // random block would read/write past the allocation.
        guard randomBlockBytes <= sequentialBlockBytes else {
            throw BenchmarkError.invalidConfiguration(
                "randomBlockBytes must not exceed sequentialBlockBytes")
        }
        guard fileSizeBytes > 0,
              fileSizeBytes % UInt64(sequentialBlockBytes) == 0 else {
            throw BenchmarkError.invalidConfiguration(
                "fileSizeBytes must be a positive multiple of sequentialBlockBytes")
        }
        // Sane ceiling (1 TiB) — keeps off_t conversions trap-free and blocks
        // absurd accidental sizes long before ENOSPC would.
        guard fileSizeBytes <= (1 << 40) else {
            throw BenchmarkError.invalidConfiguration(
                "fileSizeBytes must be at most 1 TiB")
        }
        guard fileSizeBytes >= UInt64(randomBlockBytes) else {
            throw BenchmarkError.invalidConfiguration(
                "fileSizeBytes must be at least one random block")
        }
    }
}

public enum BenchmarkPhase: String, Sendable, Codable, CaseIterable {
    case sequentialWrite, sequentialRead, randomWrite, randomRead
}

/// One progress emission, roughly 5 Hz.
public struct BenchmarkProgress: Sendable {
    public let phase: BenchmarkPhase
    public let fractionCompleted: Double            // 0...1 within the phase
    public let instantaneousBytesPerSecond: Double  // since the previous emission
    public let averageBytesPerSecond: Double        // since the phase started

    public init(phase: BenchmarkPhase, fractionCompleted: Double,
                instantaneousBytesPerSecond: Double, averageBytesPerSecond: Double) {
        self.phase = phase
        self.fractionCompleted = fractionCompleted
        self.instantaneousBytesPerSecond = instantaneousBytesPerSecond
        self.averageBytesPerSecond = averageBytesPerSecond
    }
}

public struct BenchmarkResult: Sendable, Codable, Hashable {
    public let capturedAt: Date
    public let volumeBSDName: String        // e.g. "disk3s1"
    public let volumeName: String           // e.g. "Macintosh HD"
    public let mountPoint: String
    public let fileSizeBytes: UInt64        // config echo
    public let sequentialBlockBytes: Int
    public let randomBlockBytes: Int
    public let sequentialWriteBytesPerSec: Double
    public let sequentialReadBytesPerSec: Double
    public let randomWriteBytesPerSec: Double?   // nil when random phases skipped
    public let randomReadBytesPerSec: Double?

    public init(capturedAt: Date, volumeBSDName: String, volumeName: String,
                mountPoint: String, fileSizeBytes: UInt64, sequentialBlockBytes: Int,
                randomBlockBytes: Int, sequentialWriteBytesPerSec: Double,
                sequentialReadBytesPerSec: Double,
                randomWriteBytesPerSec: Double?, randomReadBytesPerSec: Double?) {
        self.capturedAt = capturedAt
        self.volumeBSDName = volumeBSDName
        self.volumeName = volumeName
        self.mountPoint = mountPoint
        self.fileSizeBytes = fileSizeBytes
        self.sequentialBlockBytes = sequentialBlockBytes
        self.randomBlockBytes = randomBlockBytes
        self.sequentialWriteBytesPerSec = sequentialWriteBytesPerSec
        self.sequentialReadBytesPerSec = sequentialReadBytesPerSec
        self.randomWriteBytesPerSec = randomWriteBytesPerSec
        self.randomReadBytesPerSec = randomReadBytesPerSec
    }

    public var randomWriteIOPS: Double? {
        randomBlockBytes > 0 ? randomWriteBytesPerSec.map { $0 / Double(randomBlockBytes) } : nil
    }
    public var randomReadIOPS: Double? {
        randomBlockBytes > 0 ? randomReadBytesPerSec.map { $0 / Double(randomBlockBytes) } : nil
    }
}

public enum BenchmarkError: Error, LocalizedError, Equatable {
    case invalidConfiguration(String)
    case volumeNotWritable(mountPoint: String)
    case insufficientFreeSpace(requiredBytes: UInt64, availableBytes: UInt64)
    case fileTooLargeForFilesystem(maximumBytes: UInt64)
    case fileCreationFailed(path: String, errno: Int32)
    case ioFailed(operation: String, errno: Int32)
    case shortIO(expectedBytes: Int, actualBytes: Int)
    /// The volume ran out of space mid-run (free-space TOCTOU).
    case diskFull
    case cancelled
    case alreadyRunning

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let detail):
            return String(localized: "benchmark.error.config",
                          defaultValue: "Cấu hình benchmark không hợp lệ: \(detail)",
                          bundle: .module)
        case .volumeNotWritable(let mountPoint):
            return String(localized: "benchmark.error.readonly",
                          defaultValue: "Không ghi được lên volume \(mountPoint) (chỉ đọc?).",
                          bundle: .module)
        case .insufficientFreeSpace(let required, let available):
            return String(localized: "benchmark.error.space",
                          defaultValue: "Không đủ dung lượng trống: cần \(required) byte, còn \(available) byte.",
                          bundle: .module)
        case .fileTooLargeForFilesystem(let maximum):
            return String(localized: "benchmark.error.filesize",
                          defaultValue: "Định dạng ổ này giới hạn file tối đa \(maximum) byte — hãy chọn cỡ nhỏ hơn.",
                          bundle: .module)
        case .fileCreationFailed(let path, let errno):
            return String(localized: "benchmark.error.create",
                          defaultValue: "Không tạo được file kiểm tra tại \(path) (errno \(errno)).",
                          bundle: .module)
        case .ioFailed(let operation, let errno):
            return String(localized: "benchmark.error.io",
                          defaultValue: "Lỗi \(operation) khi đo (errno \(errno)).",
                          bundle: .module)
        case .shortIO(let expected, let actual):
            return String(localized: "benchmark.error.short",
                          defaultValue: "Đọc/ghi thiếu: mong \(expected) byte, được \(actual) byte.",
                          bundle: .module)
        case .diskFull:
            return String(localized: "benchmark.error.diskFull",
                          defaultValue: "Volume bị đầy giữa lúc đo — hãy giải phóng thêm dung lượng rồi thử lại.",
                          bundle: .module)
        case .cancelled:
            return String(localized: "benchmark.error.cancelled",
                          defaultValue: "Đã huỷ benchmark.",
                          bundle: .module)
        case .alreadyRunning:
            return String(localized: "benchmark.error.running",
                          defaultValue: "Đang có một benchmark khác chạy.",
                          bundle: .module)
        }
    }
}
