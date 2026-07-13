/*
 * CapacityVerifier.swift — H2testw-style fake-capacity detection.
 *
 * Fake-capacity flash (a real community plague: "2 TB" USB sticks with 32 GB
 * of NAND that silently wrap writes) passes every SMART check and even short
 * benchmarks. The only reliable userspace test is H2testw's: fill the free
 * space with deterministic pseudo-random data, read it back, and verify —
 * on a wrapped controller the blocks written past the real capacity corrupt
 * earlier data, so verification pinpoints where the real storage ends.
 *
 * Same I/O discipline as DiskBenchmarkEngine: F_NOCACHE, page-aligned
 * buffers/offsets, files capped at 1 GiB (FAT32-safe), guaranteed cleanup.
 *
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import Foundation

public struct CapacityVerifyConfig: Sendable, Hashable {
    /// Free space to leave untouched (the OS misbehaves at 0 B free).
    public var reserveBytes: UInt64
    /// Size of each test file (multiple files: FAT32 caps files at 4 GiB − 1).
    public var fileSizeBytes: UInt64
    /// I/O block size — also the verification granularity.
    public var blockBytes: Int
    /// Optional cap on how much to test (nil = fill all free space). Lets
    /// tests and impatient users bound the run.
    public var maxBytes: UInt64?

    public init(reserveBytes: UInt64 = 512 << 20,
                fileSizeBytes: UInt64 = 1 << 30,
                blockBytes: Int = 4 << 20,
                maxBytes: UInt64? = nil) {
        self.reserveBytes = reserveBytes
        self.fileSizeBytes = fileSizeBytes
        self.blockBytes = blockBytes
        self.maxBytes = maxBytes
    }

    public func validate() throws {
        guard blockBytes > 0, blockBytes % BenchmarkConfig.pageSize == 0 else {
            throw BenchmarkError.invalidConfiguration(
                "blockBytes must be a positive multiple of 4096")
        }
        guard fileSizeBytes > 0, fileSizeBytes % UInt64(blockBytes) == 0,
              fileSizeBytes < (1 << 32) else {
            throw BenchmarkError.invalidConfiguration(
                "fileSizeBytes must be a multiple of blockBytes and under 4 GiB")
        }
        // A cap below one block floors the target to zero — run() would then
        // write nothing and report a false "genuine" verdict.
        if let cap = maxBytes {
            guard cap >= UInt64(blockBytes) else {
                throw BenchmarkError.invalidConfiguration(
                    "maxBytes must be at least one block")
            }
        }
    }
}

public enum CapacityVerifyPhase: String, Sendable {
    case filling, verifying
}

public struct CapacityVerifyProgress: Sendable {
    public let phase: CapacityVerifyPhase
    public let fractionCompleted: Double
    public let bytesProcessed: UInt64
    public let totalBytes: UInt64
    public let instantaneousBytesPerSecond: Double
}

public struct CapacityVerifyResult: Sendable, Hashable {
    public enum Verdict: Sendable, Hashable {
        /// Every written byte read back intact.
        case genuine
        /// Data corrupted from `firstCorruptionOffset` on — the hallmark of a
        /// fake-capacity controller wrapping writes.
        case fake
        /// I/O errors interrupted the test before a verdict was possible.
        case inconclusive
    }

    public let capturedAt: Date
    public let volumeName: String
    public let mountPoint: String
    public let bytesWritten: UInt64
    public let bytesVerifiedOK: UInt64
    /// Global byte offset (across all test data) of the first mismatch.
    public let firstCorruptionOffset: UInt64?
    public let corruptedBlocks: Int
    public let writeBytesPerSec: Double
    public let readBytesPerSec: Double
    public let verdict: Verdict
}

public final class CapacityVerifier: @unchecked Sendable {
    public typealias ProgressHandler = @Sendable (CapacityVerifyProgress) -> Void

    public static let testDirectoryName = ".com.maclife.mdrivehealth.capacitytest"

    private static let runLock = NSLock()

    public init() {}

    /// Directory the test files live in for a volume (hidden, constant —
    /// leftovers from a crashed run are reclaimed on the next start).
    public static func testDirectoryURL(for volume: VolumeUsage) -> URL {
        if volume.mountPoint == "/" {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent(testDirectoryName, isDirectory: true)
        }
        return URL(fileURLWithPath: volume.mountPoint, isDirectory: true)
            .appendingPathComponent(testDirectoryName, isDirectory: true)
    }

    /// Fills the volume's free space (minus reserve) with keyed pseudo-random
    /// data, reads everything back, and verifies. Blocking — call off the
    /// main thread. The test files are always removed before returning.
    public func run(volume: VolumeUsage,
                    config: CapacityVerifyConfig = CapacityVerifyConfig(),
                    isCancelled: @escaping @Sendable () -> Bool = { false },
                    progress: @escaping ProgressHandler = { _ in }) throws -> CapacityVerifyResult {
        guard Self.runLock.try() else { throw BenchmarkError.alreadyRunning }
        defer { Self.runLock.unlock() }
        try config.validate()

        let directory = Self.testDirectoryURL(for: volume)
        try? FileManager.default.removeItem(at: directory)   // reclaim leftovers
        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
        } catch {
            throw BenchmarkError.fileCreationFailed(path: directory.path, errno: EIO)
        }
        defer { try? FileManager.default.removeItem(at: directory) }

        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Capacity verification")
        defer { ProcessInfo.processInfo.endActivity(activity) }

        // Live free space (the snapshot may be stale).
        let values = try? directory.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        ])
        // Clamp: importantUsage is Int64 and can be NEGATIVE on APFS edge
        // cases — a bare UInt64.init would trap.
        let free = (values?.volumeAvailableCapacityForImportantUsage).map { UInt64(max(0, $0)) }
            ?? (values?.volumeAvailableCapacity).map { UInt64(max(0, $0)) }
            ?? volume.availableBytes
        guard free > config.reserveBytes + UInt64(config.blockBytes) else {
            throw BenchmarkError.insufficientFreeSpace(
                requiredBytes: config.reserveBytes + UInt64(config.blockBytes),
                availableBytes: free)
        }
        var target = free - config.reserveBytes
        if let cap = config.maxBytes { target = min(target, cap) }
        // Whole blocks only — the tail sub-block isn't worth the alignment loss.
        target -= target % UInt64(config.blockBytes)
        guard target >= UInt64(config.blockBytes) else {
            throw BenchmarkError.insufficientFreeSpace(
                requiredBytes: config.reserveBytes + UInt64(config.blockBytes),
                availableBytes: free)
        }

        let seed = UInt64.random(in: .min ... .max)
        let capturedAt = Date()

        let written = try fill(directory: directory, target: target, seed: seed,
                               config: config, isCancelled: isCancelled,
                               progress: progress)
        let verify = try verify(directory: directory, expectedBytes: written.bytes,
                                seed: seed, config: config,
                                isCancelled: isCancelled, progress: progress)

        // Corruption anywhere = fake, even if reads also errored. Read errors
        // with no corruption proven = inconclusive (never a false "genuine").
        let verdict: CapacityVerifyResult.Verdict
        if verify.firstCorruption != nil {
            verdict = .fake
        } else if verify.readErrorEncountered {
            verdict = .inconclusive
        } else {
            verdict = .genuine
        }
        return CapacityVerifyResult(
            capturedAt: capturedAt,
            volumeName: volume.name, mountPoint: volume.mountPoint,
            bytesWritten: written.bytes,
            bytesVerifiedOK: verify.okBytes,
            firstCorruptionOffset: verify.firstCorruption,
            corruptedBlocks: verify.corruptedBlocks,
            writeBytesPerSec: written.bytesPerSec,
            readBytesPerSec: verify.bytesPerSec,
            verdict: verdict)
    }

    // MARK: - Pattern generation (SplitMix64 — deterministic per block)

    /// Fills `buffer` with the keyed pattern for a global block index.
    /// Deterministic: verification regenerates the exact bytes from
    /// (seed, blockIndex) without storing anything.
    static func fillPattern(buffer: UnsafeMutableRawPointer, byteCount: Int,
                            seed: UInt64, blockIndex: UInt64) {
        var state = seed ^ (blockIndex &* 0x9E37_79B9_7F4A_7C15)
        let words = buffer.bindMemory(to: UInt64.self, capacity: byteCount / 8)
        for i in 0..<(byteCount / 8) {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            words[i] = z ^ (z >> 31)
        }
    }

    // MARK: - Phases

    // Internal (not private): tests drive fill/verify separately so they can
    // corrupt a file in between and prove detection works.
    struct FillOutcome { let bytes: UInt64; let bytesPerSec: Double }
    struct VerifyOutcome {
        let okBytes: UInt64
        let firstCorruption: UInt64?
        let corruptedBlocks: Int
        /// Read failed mid-verify (fake drives often EIO past the wrap
        /// point) — verification stopped early but collected evidence stands.
        let readErrorEncountered: Bool
        let bytesPerSec: Double
    }

    func fill(directory: URL, target: UInt64, seed: UInt64,
              config: CapacityVerifyConfig,
              isCancelled: @Sendable () -> Bool,
              progress: ProgressHandler) throws -> FillOutcome {
        let block = config.blockBytes
        var raw: UnsafeMutableRawPointer?
        let allocError = posix_memalign(&raw, BenchmarkConfig.pageSize, block)
        guard allocError == 0, let buffer = raw else {
            throw BenchmarkError.ioFailed(operation: "posix_memalign", errno: allocError)
        }
        defer { free(buffer) }

        let clock = ContinuousClock()
        let start = clock.now
        var lastEmit = start
        var lastBytes: UInt64 = 0
        var globalBlock: UInt64 = 0
        var written: UInt64 = 0
        var fileIndex = 0

        while written < target {
            let path = directory.appendingPathComponent(String(format: "%04d.bin", fileIndex)).path
            let fd = open(path, O_CREAT | O_WRONLY | O_EXCL, 0o600)
            guard fd >= 0 else {
                throw BenchmarkError.fileCreationFailed(path: path, errno: errno)
            }
            _ = fcntl(fd, F_NOCACHE, 1)
            var fileBytes: UInt64 = 0

            while fileBytes < config.fileSizeBytes, written < target {
                if isCancelled() { close(fd); throw BenchmarkError.cancelled }
                Self.fillPattern(buffer: buffer, byteCount: block,
                                 seed: seed, blockIndex: globalBlock)
                let n = pwrite(fd, buffer, block, off_t(fileBytes))
                guard n == block else {
                    let failure = errno
                    close(fd)
                    // Running out of space here is EXPECTED (we fill to the
                    // brim of the reserve) — stop filling and verify what
                    // fits. That shows up either as -1/ENOSPC (nothing fit)
                    // or, far more commonly, a PARTIAL write (n < block:
                    // space ran out mid-request). The partial tail block is
                    // discarded; `written` only ever counts whole blocks.
                    if (n == -1 && failure == ENOSPC) || (n >= 0 && n < block) {
                        return FillOutcome(
                            bytes: written,
                            bytesPerSec: rate(bytes: written, since: start, clock: clock))
                    }
                    throw BenchmarkError.ioFailed(operation: "pwrite", errno: failure)
                }
                fileBytes += UInt64(block)
                written += UInt64(block)
                globalBlock += 1

                let now = clock.now
                if seconds(lastEmit.duration(to: now)) >= 0.2 {
                    let instant = Double(written - lastBytes)
                        / seconds(lastEmit.duration(to: now))
                    progress(CapacityVerifyProgress(
                        phase: .filling,
                        fractionCompleted: Double(written) / Double(max(target, 1)),
                        bytesProcessed: written, totalBytes: target,
                        instantaneousBytesPerSecond: instant))
                    lastEmit = now
                    lastBytes = written
                }
            }
            _ = fcntl(fd, F_FULLFSYNC, 0)
            close(fd)
            fileIndex += 1
        }
        return FillOutcome(bytes: written,
                           bytesPerSec: rate(bytes: written, since: start, clock: clock))
    }

    func verify(directory: URL, expectedBytes: UInt64, seed: UInt64,
                config: CapacityVerifyConfig,
                isCancelled: @Sendable () -> Bool,
                progress: ProgressHandler) throws -> VerifyOutcome {
        let block = config.blockBytes
        var rawRead: UnsafeMutableRawPointer?
        var rawExpect: UnsafeMutableRawPointer?
        let e1 = posix_memalign(&rawRead, BenchmarkConfig.pageSize, block)
        let e2 = posix_memalign(&rawExpect, BenchmarkConfig.pageSize, block)
        guard e1 == 0, e2 == 0, let readBuffer = rawRead, let expectBuffer = rawExpect else {
            throw BenchmarkError.ioFailed(operation: "posix_memalign", errno: e1 != 0 ? e1 : e2)
        }
        defer { free(readBuffer); free(expectBuffer) }

        let clock = ContinuousClock()
        let start = clock.now
        var lastEmit = start
        var lastBytes: UInt64 = 0
        var processed: UInt64 = 0
        var okBytes: UInt64 = 0
        var firstCorruption: UInt64?
        var corruptedBlocks = 0
        var globalBlock: UInt64 = 0
        var fileIndex = 0

        while processed < expectedBytes {
            let path = directory.appendingPathComponent(String(format: "%04d.bin", fileIndex)).path
            let fd = open(path, O_RDONLY)
            guard fd >= 0 else {
                // Whole file unreadable — stop, but keep the evidence
                // gathered so far instead of discarding it with a throw.
                return VerifyOutcome(okBytes: okBytes, firstCorruption: firstCorruption,
                                     corruptedBlocks: corruptedBlocks,
                                     readErrorEncountered: true,
                                     bytesPerSec: rate(bytes: processed, since: start, clock: clock))
            }
            _ = fcntl(fd, F_NOCACHE, 1)
            var fileBytes: UInt64 = 0

            while fileBytes < config.fileSizeBytes, processed < expectedBytes {
                if isCancelled() { close(fd); throw BenchmarkError.cancelled }
                let n = pread(fd, readBuffer, block, off_t(fileBytes))
                guard n == block else {
                    close(fd)
                    // Fake drives often return EIO past the wrap point.
                    // A read failure is itself evidence — return the partial
                    // outcome (fake if corruption already seen, else
                    // inconclusive) rather than aborting with a raw error.
                    return VerifyOutcome(okBytes: okBytes, firstCorruption: firstCorruption,
                                         corruptedBlocks: corruptedBlocks,
                                         readErrorEncountered: true,
                                         bytesPerSec: rate(bytes: processed, since: start, clock: clock))
                }
                Self.fillPattern(buffer: expectBuffer, byteCount: block,
                                 seed: seed, blockIndex: globalBlock)
                if memcmp(readBuffer, expectBuffer, block) == 0 {
                    okBytes += UInt64(block)
                } else {
                    corruptedBlocks += 1
                    if firstCorruption == nil {
                        firstCorruption = processed
                    }
                }
                fileBytes += UInt64(block)
                processed += UInt64(block)
                globalBlock += 1

                let now = clock.now
                if seconds(lastEmit.duration(to: now)) >= 0.2 {
                    let instant = Double(processed - lastBytes)
                        / seconds(lastEmit.duration(to: now))
                    progress(CapacityVerifyProgress(
                        phase: .verifying,
                        fractionCompleted: Double(processed) / Double(max(expectedBytes, 1)),
                        bytesProcessed: processed, totalBytes: expectedBytes,
                        instantaneousBytesPerSecond: instant))
                    lastEmit = now
                    lastBytes = processed
                }
            }
            close(fd)
            fileIndex += 1
        }
        return VerifyOutcome(okBytes: okBytes, firstCorruption: firstCorruption,
                             corruptedBlocks: corruptedBlocks,
                             readErrorEncountered: false,
                             bytesPerSec: rate(bytes: processed, since: start, clock: clock))
    }

    // MARK: - Helpers

    private func rate(bytes: UInt64, since start: ContinuousClock.Instant,
                      clock: ContinuousClock) -> Double {
        let elapsed = seconds(start.duration(to: clock.now))
        return elapsed > 0 ? Double(bytes) / elapsed : 0
    }

    private func seconds(_ duration: Duration) -> Double {
        let c = duration.components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}
