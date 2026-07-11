/*
 * DiskBenchmarkEngine.swift — file-based sequential + random disk benchmark.
 *
 * Bypasses the unified buffer cache with F_NOCACHE and fully page-aligned
 * (buffer, offset, length) I/O — an unaligned F_NOCACHE request silently
 * reverts to cached I/O and would measure RAM. Blocking; call off the main
 * thread. The test file is removed on every exit path.
 *
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import Foundation

public final class DiskBenchmarkEngine: @unchecked Sendable {
    public typealias ProgressHandler = @Sendable (BenchmarkProgress) -> Void

    /// Guards against two concurrent runs in one process (the app's state
    /// machine is the primary guard; this catches programmer error).
    private static let runLock = NSLock()

    public init() {}

    /// Runs the full benchmark on a mounted, writable volume. Blocking —
    /// call from a background task/thread. `progress` fires ~5 Hz on the
    /// calling thread. Throws `BenchmarkError`.
    public func run(volume: VolumeUsage,
                    config: BenchmarkConfig = BenchmarkConfig(),
                    isCancelled: @escaping @Sendable () -> Bool = { false },
                    progress: @escaping ProgressHandler = { _ in }) throws -> BenchmarkResult {
        let url = try BenchmarkLocation.preflight(volume: volume, config: config)
        return try run(testFileURL: url, volume: volume, config: config,
                       isCancelled: isCancelled, progress: progress)
    }

    /// Test seam: skips preflight and benchmarks an explicit file URL.
    /// `volume` only labels the result.
    func run(testFileURL url: URL, volume: VolumeUsage, config: BenchmarkConfig,
             isCancelled: @escaping @Sendable () -> Bool,
             progress: @escaping ProgressHandler) throws -> BenchmarkResult {
        guard Self.runLock.try() else { throw BenchmarkError.alreadyRunning }
        defer { Self.runLock.unlock() }

        try config.validate()
        let capturedAt = Date()
        let path = url.path
        let seqBlock = config.sequentialBlockBytes
        let fileSize = config.fileSizeBytes

        // Reclaim a leftover from a crashed run, then create fresh.
        unlink(path)
        let fd = open(path, O_CREAT | O_RDWR | O_EXCL, 0o600)
        guard fd >= 0 else {
            throw BenchmarkError.fileCreationFailed(path: path, errno: errno)
        }
        // Established immediately so success, cancellation, and every throw
        // all close the descriptor and delete the file.
        defer { close(fd); unlink(path) }

        guard fcntl(fd, F_NOCACHE, 1) != -1 else {
            throw BenchmarkError.ioFailed(operation: "fcntl(F_NOCACHE)", errno: errno)
        }
        _ = fcntl(fd, F_RDAHEAD, 0)   // readahead is moot under F_NOCACHE; document intent

        try preallocate(fd: fd, fileSize: fileSize)

        // Four incompressible buffers, page-aligned (an F_NOCACHE requirement),
        // rotated to defeat controller-side dedup/compression.
        var buffers: [UnsafeMutableRawPointer] = []
        defer { buffers.forEach { free($0) } }
        for _ in 0..<4 {
            var raw: UnsafeMutableRawPointer?
            // posix_memalign returns its error code and does NOT set errno.
            let allocError = posix_memalign(&raw, BenchmarkConfig.pageSize, seqBlock)
            guard allocError == 0, let buf = raw else {
                throw BenchmarkError.ioFailed(operation: "posix_memalign", errno: allocError)
            }
            arc4random_buf(buf, seqBlock)
            buffers.append(buf)
        }

        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Disk speed benchmark")
        defer { ProcessInfo.processInfo.endActivity(activity) }

        // Phase 1 — sequential write (must run before any read: preallocated
        // but unwritten extents read back as synthesized zeros).
        let seqWrite = try sequentialPhase(
            .sequentialWrite, fd: fd, buffers: buffers, blockBytes: seqBlock,
            fileSize: fileSize, isCancelled: isCancelled, progress: progress)
        try fullSync(fd: fd)

        // Phase 2 — sequential read.
        let seqRead = try sequentialPhase(
            .sequentialRead, fd: fd, buffers: buffers, blockBytes: seqBlock,
            fileSize: fileSize, isCancelled: isCancelled, progress: progress)

        var randWrite: Double?
        var randRead: Double?
        if config.includeRandomPhases {
            randWrite = try randomPhase(
                .randomWrite, fd: fd, buffers: buffers, blockBytes: config.randomBlockBytes,
                fileSize: fileSize, seconds: config.randomPhaseSeconds,
                isCancelled: isCancelled, progress: progress)
            try fullSync(fd: fd)
            randRead = try randomPhase(
                .randomRead, fd: fd, buffers: buffers, blockBytes: config.randomBlockBytes,
                fileSize: fileSize, seconds: config.randomPhaseSeconds,
                isCancelled: isCancelled, progress: progress)
        }

        return BenchmarkResult(
            capturedAt: capturedAt,
            volumeBSDName: volume.bsdName, volumeName: volume.name,
            mountPoint: volume.mountPoint, fileSizeBytes: fileSize,
            sequentialBlockBytes: seqBlock, randomBlockBytes: config.randomBlockBytes,
            sequentialWriteBytesPerSec: seqWrite, sequentialReadBytesPerSec: seqRead,
            randomWriteBytesPerSec: randWrite, randomReadBytesPerSec: randRead)
    }

    // MARK: - Pure helpers (unit-tested)

    static func blockCount(fileSizeBytes: UInt64, blockBytes: Int) -> UInt64 {
        blockBytes > 0 ? fileSizeBytes / UInt64(blockBytes) : 0
    }

    /// Always `index * blockBytes`, so every offset is blockBytes-aligned
    /// (hence 4 KiB-aligned) by construction.
    static func offset(forBlockIndex index: UInt64, blockBytes: Int) -> off_t {
        off_t(index &* UInt64(blockBytes))
    }

    // MARK: - Phases

    private func sequentialPhase(_ phase: BenchmarkPhase, fd: Int32,
                                 buffers: [UnsafeMutableRawPointer], blockBytes: Int,
                                 fileSize: UInt64, isCancelled: () -> Bool,
                                 progress: ProgressHandler) throws -> Double {
        let isWrite = (phase == .sequentialWrite)
        let total = Self.blockCount(fileSizeBytes: fileSize, blockBytes: blockBytes)
        let clock = ContinuousClock()
        let start = clock.now
        var emitter = ProgressEmitter(phase: phase, clock: clock)
        // force: the very first emission would otherwise be swallowed by the
        // 0.2 s rate gate, lagging the UI phase label by a tick.
        emitter.emit(fraction: 0, totalBytes: 0, progress: progress, force: true)

        for i in 0..<total {
            if isCancelled() { throw BenchmarkError.cancelled }
            let buffer = buffers[Int(i % 4)]
            let off = Self.offset(forBlockIndex: i, blockBytes: blockBytes)
            let n = isWrite
                ? pwrite(fd, buffer, blockBytes, off)
                : pread(fd, buffer, blockBytes, off)
            guard n != -1 else {
                // A volume filling up mid-run deserves the friendly message,
                // not a raw errno (preflight's free-space check is TOCTOU).
                if errno == ENOSPC { throw BenchmarkError.diskFull }
                throw BenchmarkError.ioFailed(operation: isWrite ? "pwrite" : "pread",
                                              errno: errno)
            }
            guard n == blockBytes else {
                throw BenchmarkError.shortIO(expectedBytes: blockBytes, actualBytes: n)
            }
            let done = (i &+ 1) &* UInt64(blockBytes)
            emitter.emit(fraction: Double(i &+ 1) / Double(total),
                         totalBytes: done, progress: progress)
        }
        let elapsed = seconds(start.duration(to: clock.now))
        emitter.emit(fraction: 1, totalBytes: fileSize, progress: progress, force: true)
        return elapsed > 0 ? Double(fileSize) / elapsed : 0
    }

    private func randomPhase(_ phase: BenchmarkPhase, fd: Int32,
                             buffers: [UnsafeMutableRawPointer], blockBytes: Int,
                             fileSize: UInt64, seconds budget: TimeInterval,
                             isCancelled: () -> Bool,
                             progress: ProgressHandler) throws -> Double {
        let isWrite = (phase == .randomWrite)
        let blocks = Self.blockCount(fileSizeBytes: fileSize, blockBytes: blockBytes)
        guard blocks > 0 else { return 0 }
        var rng = SystemRandomNumberGenerator()
        let clock = ContinuousClock()
        let start = clock.now
        var emitter = ProgressEmitter(phase: phase, clock: clock)
        // force: the very first emission would otherwise be swallowed by the
        // 0.2 s rate gate, lagging the UI phase label by a tick.
        emitter.emit(fraction: 0, totalBytes: 0, progress: progress, force: true)

        var ops: UInt64 = 0
        var elapsed = 0.0
        while elapsed < budget {
            if isCancelled() { throw BenchmarkError.cancelled }
            let idx = UInt64.random(in: 0..<blocks, using: &rng)
            let buffer = buffers[Int(ops % 4)]
            let off = Self.offset(forBlockIndex: idx, blockBytes: blockBytes)
            let n = isWrite
                ? pwrite(fd, buffer, blockBytes, off)
                : pread(fd, buffer, blockBytes, off)
            guard n != -1 else {
                // A volume filling up mid-run deserves the friendly message,
                // not a raw errno (preflight's free-space check is TOCTOU).
                if errno == ENOSPC { throw BenchmarkError.diskFull }
                throw BenchmarkError.ioFailed(operation: isWrite ? "pwrite" : "pread",
                                              errno: errno)
            }
            guard n == blockBytes else {
                throw BenchmarkError.shortIO(expectedBytes: blockBytes, actualBytes: n)
            }
            ops &+= 1
            elapsed = seconds(start.duration(to: clock.now))
            emitter.emit(fraction: min(1, elapsed / budget),
                         totalBytes: ops &* UInt64(blockBytes), progress: progress)
        }
        emitter.emit(fraction: 1, totalBytes: ops &* UInt64(blockBytes),
                     progress: progress, force: true)
        return elapsed > 0 ? Double(ops &* UInt64(blockBytes)) / elapsed : 0
    }

    // MARK: - Syscall wrappers

    private func preallocate(fd: Int32, fileSize: UInt64) throws {
        var store = fstore_t()
        store.fst_flags = UInt32(F_ALLOCATECONTIG | F_ALLOCATEALL)
        store.fst_posmode = F_PEOFPOSMODE
        store.fst_offset = 0
        store.fst_length = off_t(fileSize)
        if fcntl(fd, F_PREALLOCATE, &store) == -1 {
            // Fragmented volume: retry without requiring one contiguous run.
            store.fst_flags = UInt32(F_ALLOCATEALL)
            _ = fcntl(fd, F_PREALLOCATE, &store)
            // Preallocation is unsupported on some filesystems (exFAT/msdos);
            // ftruncate below still sizes the file, and ENOSPC surfaces there.
        }
        guard ftruncate(fd, off_t(fileSize)) == 0 else {
            throw BenchmarkError.ioFailed(operation: "ftruncate", errno: errno)
        }
    }

    /// Flushes the drive's write cache to media. Runs between phases for
    /// durability but is excluded from throughput timing, matching
    /// Blackmagic / AmorphousDiskMark / CrystalDiskMark.
    private func fullSync(fd: Int32) throws {
        guard fcntl(fd, F_FULLFSYNC, 0) != -1 else {
            throw BenchmarkError.ioFailed(operation: "F_FULLFSYNC", errno: errno)
        }
    }

    private func seconds(_ duration: Duration) -> Double {
        let c = duration.components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}

/// Rate-limits progress emission to ~5 Hz and tracks instantaneous throughput.
private struct ProgressEmitter {
    let phase: BenchmarkPhase
    let clock: ContinuousClock
    let start: ContinuousClock.Instant
    var lastEmit: ContinuousClock.Instant
    var lastBytes: UInt64 = 0

    init(phase: BenchmarkPhase, clock: ContinuousClock) {
        self.phase = phase
        self.clock = clock
        self.start = clock.now
        self.lastEmit = start
    }

    mutating func emit(fraction: Double, totalBytes: UInt64,
                       progress: DiskBenchmarkEngine.ProgressHandler,
                       force: Bool = false) {
        let now = clock.now
        let sinceEmit = seconds(lastEmit.duration(to: now))
        guard force || sinceEmit >= 0.2 else { return }
        let instant = sinceEmit > 0
            ? Double(totalBytes &- lastBytes) / sinceEmit : 0
        let sinceStart = seconds(start.duration(to: now))
        let average = sinceStart > 0 ? Double(totalBytes) / sinceStart : 0
        progress(BenchmarkProgress(
            phase: phase, fractionCompleted: min(1, max(0, fraction)),
            instantaneousBytesPerSecond: max(0, instant),
            averageBytesPerSecond: average))
        lastEmit = now
        lastBytes = totalBytes
    }

    private func seconds(_ duration: Duration) -> Double {
        let c = duration.components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}
