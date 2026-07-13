/*
 * DriveServices.swift — TRIM status lookup and safe-eject helper.
 * Both shell out to system tools (system_profiler / diskutil / lsof), so
 * they live in the App layer, not core.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import Foundation
import MDriveHealthCore

// MARK: - TRIM

enum TrimStatusReader {
    /// TRIM/Deallocate support as System Information reports it; nil when
    /// the drive isn't listed (virtual, USB) or the lookup fails.
    static func trimSupport(bsdName: String) async -> Bool? {
        await Task.detached(priority: .utility) { () -> Bool? in
            guard let data = runProcess(
                "/usr/sbin/system_profiler",
                ["-json", "SPNVMeDataType", "SPSerialATADataType"], timeout: 15),
                let object = try? JSONSerialization.jsonObject(with: data),
                let root = object as? [String: Any]
            else { return nil }

            for key in ["SPNVMeDataType", "SPSerialATADataType"] {
                for controller in root[key] as? [[String: Any]] ?? [] {
                    for item in controller["_items"] as? [[String: Any]] ?? [] {
                        guard item["bsd_name"] as? String == bsdName else { continue }
                        for trimKey in ["spnvme_trim_support", "spsata_trim_support"] {
                            if let value = item[trimKey] as? String {
                                return value == "Yes"
                            }
                        }
                    }
                }
            }
            return nil
        }.value
    }
}

// MARK: - Safe eject

enum EjectOutcome: Sendable {
    case ejected
    /// Unmount refused; these app/process names hold files open on it.
    case blocked([String])
    case failed(String)
}

enum EjectService {
    /// Unmounts every volume of the drive (diskutil unmountDisk). On refusal
    /// (non-forced), names the processes blocking it so the user knows what
    /// to close — macOS's own dialog never does.
    static func eject(drive: DriveInfo, volumes: [VolumeUsage],
                      force: Bool) async -> EjectOutcome {
        await Task.detached(priority: .userInitiated) { () -> EjectOutcome in
            var arguments = ["unmountDisk"]
            if force { arguments.append("force") }
            arguments.append("/dev/\(drive.bsdName)")

            let result = runProcessWithStatus("/usr/sbin/diskutil", arguments, timeout: 30)
            if result.status == 0 { return .ejected }

            if !force {
                let blockers = blockingProcesses(volumes: volumes)
                if !blockers.isEmpty { return .blocked(blockers) }
            }
            let message = String(decoding: result.output, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(message.isEmpty ? "diskutil exit \(result.status)" : message)
        }.value
    }

    /// Process names holding files open under the drive's mount points.
    private static func blockingProcesses(volumes: [VolumeUsage]) -> [String] {
        var names: Set<String> = []
        for volume in volumes where volume.mountPoint.hasPrefix("/Volumes/") {
            // -Fc → machine-readable "c<command>" lines.
            guard let data = runProcess("/usr/sbin/lsof",
                                        ["-Fc", "+f", "--", volume.mountPoint],
                                        timeout: 10) else { continue }
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n")
            where line.hasPrefix("c") {
                names.insert(String(line.dropFirst()))
            }
        }
        return names.sorted()
    }
}

// MARK: - Process helpers

private func runProcess(_ path: String, _ arguments: [String],
                        timeout: TimeInterval) -> Data? {
    let result = runProcessWithStatus(path, arguments, timeout: timeout)
    return result.status == 0 ? result.output : nil
}

private func runProcessWithStatus(_ path: String, _ arguments: [String],
                                  timeout: TimeInterval) -> (status: Int32, output: Data) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = stdout
    do {
        try process.run()
    } catch {
        return (-1, Data())
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
        if process.isRunning { process.terminate() }
    }
    // SIGTERM can be ignored; without the SIGKILL escalation a stuck child
    // would block readDataToEndOfFile() forever (spinner stuck in the UI).
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout + 2) {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, data)
}
