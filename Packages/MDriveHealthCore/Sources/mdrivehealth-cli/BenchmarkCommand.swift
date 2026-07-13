/*
 * BenchmarkCommand.swift — `mdrivehealth-cli benchmark` subcommand.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import Foundation
import MDriveHealthCore

private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var tripped = false
    func trip() { lock.lock(); tripped = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return tripped }
}

func runBenchmarkCommand(arguments: [String]) {
    guard let target = arguments.first, !target.hasPrefix("-") else {
        FileHandle.standardError.write(Data(
            "Cần chỉ định volume: mdrivehealth-cli benchmark </Volumes/X | diskNsM>\n".utf8))
        exit(2)
    }

    var config = BenchmarkConfig()
    var record = true
    var index = 1
    while index < arguments.count {
        let arg = arguments[index]
        switch arg {
        case "--size":
            index += 1
            guard index < arguments.count, let size = parseSize(arguments[index]) else {
                FileHandle.standardError.write(Data("--size cần 512m|1g|2g|5g\n".utf8)); exit(2)
            }
            config.fileSizeBytes = size
        case "--no-random":
            config.includeRandomPhases = false
        case "--no-record":
            record = false
        case "--depth":
            index += 1
            guard index < arguments.count, let depth = Int(arguments[index]),
                  (1...16).contains(depth) else {
                FileHandle.standardError.write(Data("--depth cần 1-16\n".utf8)); exit(2)
            }
            config.queueDepth = depth
        default:
            FileHandle.standardError.write(Data("Tham số lạ: \(arg)\n".utf8)); exit(2)
        }
        index += 1
    }

    guard let (volume, drive) = resolveVolume(target: target) else {
        FileHandle.standardError.write(Data("Không tìm thấy volume \"\(target)\".\n".utf8))
        exit(1)
    }

    print("Đo tốc độ: \(volume.name) (\(volume.bsdName)) tại \(volume.mountPoint)")
    print("File \(formatBytes(config.fileSizeBytes)), block \(formatBytes(UInt64(config.sequentialBlockBytes)))"
          + (config.includeRandomPhases ? " + Random 4K" : "") + "\n")

    // Ctrl-C, kill, and a closed terminal all trip the flag on a background
    // queue so cancellation is seen even while the main thread is blocked in
    // the benchmark loop; the engine's defer then deletes the (multi-GB)
    // test file instead of stranding it at the volume root.
    let cancel = CancelFlag()
    var signalSources: [DispatchSourceSignal] = []
    for sig in [SIGINT, SIGTERM, SIGHUP] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        source.setEventHandler { cancel.trip() }
        source.resume()
        signalSources.append(source)
    }
    _ = signalSources   // kept alive for the duration of the run

    do {
        let result = try DiskBenchmarkEngine().run(
            volume: volume, config: config,
            isCancelled: { cancel.isSet },
            progress: { p in
                let mbps = String(format: "%7.1f", p.instantaneousBytesPerSecond / 1e6)
                print("\r\(phaseLabel(p.phase))  \(Int(p.fractionCompleted * 100))%  \(mbps) MB/s      ",
                      terminator: "")
                fflush(stdout)
            })
        print("\r\u{1B}[K", terminator: "")   // clear the progress line

        printResult(result)
        if record {
            do {
                try HistoryStore().record(benchmark: result,
                                          driveKey: HistoryStore.driveKey(for: drive))
                print("\nĐã lưu kết quả vào lịch sử.")
            } catch {
                FileHandle.standardError.write(Data(
                    "Không lưu được lịch sử: \(error.localizedDescription)\n".utf8))
            }
        }
    } catch let error as BenchmarkError where error == .cancelled {
        print("\nĐã huỷ.")
        exit(130)
    } catch {
        FileHandle.standardError.write(Data("\nLỗi: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

// MARK: - Capacity verification

func runVerifyCapacityCommand(arguments: [String]) {
    guard let target = arguments.first, !target.hasPrefix("-") else {
        FileHandle.standardError.write(Data(
            "Cần chỉ định volume: mdrivehealth-cli verify-capacity </Volumes/X | diskNsM> [--max 512m|1g|2g|5g]\n".utf8))
        exit(2)
    }
    var config = CapacityVerifyConfig()
    var index = 1
    while index < arguments.count {
        switch arguments[index] {
        case "--max":
            index += 1
            guard index < arguments.count, let size = parseSize(arguments[index]) else {
                FileHandle.standardError.write(Data("--max cần 512m|1g|2g|5g\n".utf8)); exit(2)
            }
            config.maxBytes = size
        default:
            FileHandle.standardError.write(Data("Tham số lạ: \(arguments[index])\n".utf8)); exit(2)
        }
        index += 1
    }

    guard let (volume, _) = resolveVolume(target: target) else {
        FileHandle.standardError.write(Data("Không tìm thấy volume \"\(target)\".\n".utf8))
        exit(1)
    }

    print("Kiểm tra dung lượng thật: \(volume.name) tại \(volume.mountPoint)")
    print("Ghi kín chỗ trống rồi đọc lại so khớp — Ctrl-C để huỷ (file test tự xoá).\n")

    let cancel = CancelFlag()
    var signalSources: [DispatchSourceSignal] = []
    for sig in [SIGINT, SIGTERM, SIGHUP] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        source.setEventHandler { cancel.trip() }
        source.resume()
        signalSources.append(source)
    }
    _ = signalSources

    do {
        let result = try CapacityVerifier().run(
            volume: volume, config: config,
            isCancelled: { cancel.isSet },
            progress: { p in
                let label = p.phase == .filling ? "Ghi " : "Đọc+so"
                print("\r\(label)  \(Int(p.fractionCompleted * 100))%  \(String(format: "%7.1f", p.instantaneousBytesPerSecond / 1e6)) MB/s      ",
                      terminator: "")
                fflush(stdout)
            })
        print("\r\u{1B}[K", terminator: "")
        switch result.verdict {
        case .genuine:
            print("✅ DUNG LƯỢNG THẬT — đã xác minh \(formatBytes(result.bytesWritten)), dữ liệu khớp 100%.")
        case .fake:
            print("❌ Ổ FAKE — chỉ ~\(formatBytes(result.firstCorruptionOffset ?? 0)) lưu được thật (\(result.corruptedBlocks) block hỏng sau mốc đó).")
        case .inconclusive:
            print("⚠️ Chưa kết luận được — lỗi I/O giữa chừng.")
        }
        print(String(format: "Tốc độ: ghi %.1f MB/s · đọc %.1f MB/s",
                     result.writeBytesPerSec / 1e6, result.readBytesPerSec / 1e6))
    } catch let error as BenchmarkError where error == .cancelled {
        print("\nĐã huỷ — file test đã được xoá.")
        exit(130)
    } catch {
        FileHandle.standardError.write(Data("\nLỗi: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

// MARK: - Helpers

private func parseSize(_ raw: String) -> UInt64? {
    switch raw.lowercased() {
    case "512m", "512mb": return 1 << 29
    case "1g", "1gb": return 1 << 30
    case "2g", "2gb": return 1 << 31
    case "5g", "5gb": return 5 << 30
    default: return nil
    }
}

/// Matches `target` against every mounted volume of every drive: a
/// `/Volumes/...` mount point, a volume BSD name ("disk3s1"), or a whole-disk
/// BSD name ("disk3", using its first mounted volume).
private func resolveVolume(target: String) -> (VolumeUsage, DriveInfo)? {
    guard let drives = try? DriveEnumerator().enumerate() else { return nil }
    var firstVolumeOfDrive: (VolumeUsage, DriveInfo)?
    for drive in drives {
        let volumes = VolumeUsageReader.volumes(forDriveRegistryEntryID: drive.registryEntryID)
        for volume in volumes {
            if volume.mountPoint == target || volume.bsdName == target {
                return (volume, drive)
            }
        }
        if drive.bsdName == target, let first = volumes.first, firstVolumeOfDrive == nil {
            firstVolumeOfDrive = (first, drive)
        }
    }
    return firstVolumeOfDrive
}

private func phaseLabel(_ phase: BenchmarkPhase) -> String {
    switch phase {
    case .sequentialWrite: return "Ghi tuần tự  "
    case .sequentialRead:  return "Đọc tuần tự  "
    case .randomWrite:     return "Ghi random 4K"
    case .randomRead:      return "Đọc random 4K"
    }
}

private func mbps(_ bytesPerSec: Double) -> String {
    String(format: "%.1f MB/s", bytesPerSec / 1e6)
}

private func printResult(_ result: BenchmarkResult) {
    print("── KẾT QUẢ " + String(repeating: "─", count: 36))
    print("  Tuần tự  · Ghi:  \(mbps(result.sequentialWriteBytesPerSec))")
    print("  Tuần tự  · Đọc:  \(mbps(result.sequentialReadBytesPerSec))")
    if let rw = result.randomWriteBytesPerSec {
        print(String(format: "  Random4K · Ghi:  %@  (%.0f IOPS)", mbps(rw), result.randomWriteIOPS ?? 0))
    }
    if let rr = result.randomReadBytesPerSec {
        print(String(format: "  Random4K · Đọc:  %@  (%.0f IOPS)", mbps(rr), result.randomReadIOPS ?? 0))
    }
}
