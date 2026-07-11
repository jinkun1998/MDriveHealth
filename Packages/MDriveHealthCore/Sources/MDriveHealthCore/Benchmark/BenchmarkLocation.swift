/*
 * BenchmarkLocation.swift — where the test file lives and pre-run checks.
 * The URL/free-space logic is pure so it can be unit-tested without touching
 * a real volume; preflight() adds the live filesystem checks.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import Foundation

public enum BenchmarkLocation {
    /// Hidden, dot-prefixed so Finder ignores it; constant so a crashed run's
    /// leftover is reclaimed by unlinking before the next run.
    public static let testFileName = ".com.maclife.mdrivehealth.speedtest.tmp"
    /// FAT32 (msdos) hard limit: 4 GiB − 1.
    public static let fat32MaxFileSize: UInt64 = (1 << 32) - 1

    /// Where to write the test file for a volume. `/Volumes/X` gets a hidden
    /// file at the volume root. The boot volume mounts the sealed read-only
    /// system snapshot at "/", so its writable temp dir (on the Data volume of
    /// the same APFS container — the same physical drive) is used instead.
    public static func testFileURL(for volume: VolumeUsage) -> URL {
        if volume.mountPoint == "/" {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent(testFileName)
        }
        return URL(fileURLWithPath: volume.mountPoint, isDirectory: true)
            .appendingPathComponent(testFileName)
    }

    /// Pure free-space gate.
    public static func validateFreeSpace(availableBytes: UInt64,
                                         config: BenchmarkConfig) throws {
        if availableBytes < config.requiredFreeBytes {
            throw BenchmarkError.insufficientFreeSpace(
                requiredBytes: config.requiredFreeBytes, availableBytes: availableBytes)
        }
    }

    /// Runtime preflight: rejects read-only volumes and filesystem size caps,
    /// then re-reads live free space (never trusts a stale cached snapshot at
    /// run time) and validates it. Returns the resolved test-file URL.
    public static func preflight(volume: VolumeUsage,
                                 config: BenchmarkConfig) throws -> URL {
        try config.validate()

        let url = testFileURL(for: volume)
        let dir = url.deletingLastPathComponent()

        // Check the actual write location, not volume.mountPoint: the boot
        // volume mounts "/" read-only (the sealed system snapshot) yet its
        // temp dir on the Data volume is writable.
        var stat = statfs()
        if statfs(dir.path, &stat) == 0 {
            if stat.f_flags & UInt32(MNT_RDONLY) != 0 {
                throw BenchmarkError.volumeNotWritable(mountPoint: volume.mountPoint)
            }
            let fsType = withUnsafeBytes(of: stat.f_fstypename) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            if fsType == "msdos", config.fileSizeBytes > fat32MaxFileSize {
                throw BenchmarkError.fileTooLargeForFilesystem(maximumBytes: fat32MaxFileSize)
            }
        }

        let values = try? dir.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ])
        let important = values?.volumeAvailableCapacityForImportantUsage.map(UInt64.init)
        let plain = values?.volumeAvailableCapacity.map { UInt64(max(0, $0)) }
        // Fall back to the snapshot's cached figure only if the live read fails.
        let available = important ?? plain ?? volume.availableBytes
        try validateFreeSpace(availableBytes: available, config: config)
        return url
    }
}
