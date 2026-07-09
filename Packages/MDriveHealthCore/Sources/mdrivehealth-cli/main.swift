/*
 * main.swift — mdrivehealth-cli: terminal SMART reporter (debug/verification).
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import Foundation
import MDriveHealthCore

let arguments = Array(CommandLine.arguments.dropFirst())

func formatBytes(_ bytes: UInt64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: Int64(clamping: bytes))
}

func printUsage() {
    print("""
    mdrivehealth-cli — MDriveHealth terminal reporter

    Usage:
      mdrivehealth-cli list            Liệt kê tất cả ổ đĩa
      mdrivehealth-cli smart [diskN]   Báo cáo SMART chi tiết (mặc định: mọi ổ hỗ trợ)
      mdrivehealth-cli help
    """)
}

func listDrives(_ drives: [DriveInfo]) {
    print("Phát hiện \(drives.count) thiết bị lưu trữ:\n")
    for drive in drives {
        let kind = drive.isVirtual ? "Virtual"
                 : drive.isSolidState ? "SSD" : "HDD"
        let smart: String
        switch drive.smartInterface {
        case .nvme: smart = "SMART: NVMe"
        case .ata: smart = "SMART: ATA"
        case .unsupported: smart = drive.isVirtual ? "—" : "SMART: không khả dụng"
        }
        print("  \(drive.bsdName.padding(toLength: 8, withPad: " ", startingAt: 0))" +
              "\(drive.model.padding(toLength: 28, withPad: " ", startingAt: 0))" +
              "\(formatBytes(drive.sizeBytes).padding(toLength: 12, withPad: " ", startingAt: 0))" +
              "\(drive.interconnect) · \(drive.location) · \(kind) · \(smart)")
    }
}

func reportNVMe(_ drive: DriveInfo) {
    do {
        let reading = try NVMeSMARTProvider(drive: drive).read()
        let controller = reading.controller
        let smart = reading.smart

        print("── \(drive.bsdName): \(controller.model) " + String(repeating: "─", count: max(0, 40 - controller.model.count)))
        print("  Serial:               \(controller.serialNumber)")
        print("  Firmware:             \(controller.firmwareRevision)")
        print("  NVMe spec:            \(controller.specVersion ?? "—")")
        // Apple controllers report tnvmcap = 0; fall back to IOMedia size.
        let capacity = controller.totalCapacityBytes > 0
            ? controller.totalCapacityBytes : drive.sizeBytes
        print("  Total capacity:       \(formatBytes(capacity))")
        if controller.warningTempKelvin > 0 {
            print("  Temp thresholds:      warning \(Int(controller.warningTempKelvin) - 273)°C / critical \(Int(controller.criticalTempKelvin) - 273)°C")
        }
        print("")
        let warning = smart.criticalWarning
        print("  Critical warning:     0x\(String(warning.rawValue, radix: 16, uppercase: true)) \(warning.isEmpty ? "(OK)" : "⚠️")")
        if warning.contains(.spareBelowThreshold) { print("    ⚠️ Spare capacity dưới ngưỡng!") }
        if warning.contains(.temperatureError) { print("    ⚠️ Nhiệt độ ngoài ngưỡng an toàn!") }
        if warning.contains(.reliabilityDegraded) { print("    ⚠️ Độ tin cậy NVM suy giảm (media errors)!") }
        if warning.contains(.mediaReadOnly) { print("    ⚠️ Media đã chuyển sang chế độ chỉ đọc!") }
        if warning.contains(.volatileBackupFailed) { print("    ⚠️ Volatile memory backup hỏng!") }
        print("  Temperature:          \(smart.temperatureCelsius)°C")
        let extraSensors = smart.temperatureSensorsKelvin.filter { $0 > 0 }
        if !extraSensors.isEmpty {
            print("  Temp sensors:         \(extraSensors.map { "\(Int($0) - 273)°C" }.joined(separator: ", "))")
        }
        print("  Available spare:      \(smart.availableSpare)% (threshold \(smart.availableSpareThreshold)%)")
        print("  Percentage used:      \(smart.percentageUsed)% (SSD lifetime left ≈ \(max(0, 100 - Int(smart.percentageUsed)))%)")
        print("  Data read:            \(formatBytes(smart.bytesRead)) (\(smart.dataUnitsRead) units)")
        print("  Data written:         \(formatBytes(smart.bytesWritten)) (\(smart.dataUnitsWritten) units)")
        print("  Host read commands:   \(smart.hostReadCommands)")
        print("  Host write commands:  \(smart.hostWriteCommands)")
        print("  Controller busy:      \(smart.controllerBusyTimeMinutes) minutes")
        print("  Power cycles:         \(smart.powerCycles)")
        print("  Power-on hours:       \(smart.powerOnHours)")
        print("  Unsafe shutdowns:     \(smart.unsafeShutdowns)")
        print("  Media errors:         \(smart.mediaErrors)")
        print("  Error log entries:    \(smart.errorLogEntries)")
        print("")
    } catch {
        print("── \(drive.bsdName): \(drive.model) — LỖI: \(error.localizedDescription)\n")
    }
}

func reportATA(_ drive: DriveInfo) {
    do {
        let reading = try ATASMARTProvider(drive: drive).read()
        let model = reading.identify?.model ?? drive.model
        print("── \(drive.bsdName): \(model) " + String(repeating: "─", count: max(0, 40 - model.count)))
        if let identify = reading.identify {
            print("  Serial:               \(identify.serialNumber)")
            print("  Firmware:             \(identify.firmwareRevision)")
            print("  Medium:               \(identify.isSolidState ? "SSD" : identify.rpm.map { "HDD \($0) rpm" } ?? "HDD")")
        }
        if let family = reading.driveFamily {
            print("  Model family:         \(family)")
        }
        if let warning = reading.driveWarning {
            print("  ⚠️ drivedb warning:    \(warning)")
        }
        if let failing = reading.overallFailurePredicted {
            print("  SMART overall:        \(failing ? "FAILING — thresholds exceeded ⚠️" : "PASSED")")
        }
        if let selfTest = reading.selfTest, selfTest.inProgress {
            print("  Self-test:            đang chạy, còn \(selfTest.percentRemaining ?? 0)%")
        }
        print("")
        print("  ID# ATTRIBUTE_NAME             FLAG  VALUE WORST THRESH TYPE     RAW")
        for attr in reading.attributes {
            let name = attr.name.padding(toLength: 26, withPad: " ", startingAt: 0)
            let flag = String(format: "0x%04x", attr.flags)
            let type = attr.isPrefail ? "Pre-fail" : "Old_age "
            let thresh = attr.threshold.map { String(format: "%5d", Int($0)) } ?? "    —"
            let marker = attr.failedNow ? "  ← FAILING NOW" : (attr.failedEver ? "  ← failed in past" : "")
            print("  \(String(format: "%3d", Int(attr.attributeID))) \(name) \(flag) \(String(format: "%5d", Int(attr.current))) \(String(format: "%5d", Int(attr.worst))) \(thresh) \(type) \(attr.rawDisplay)\(marker)")
        }
        print("")
    } catch {
        print("── \(drive.bsdName): \(drive.model) — LỖI: \(error.localizedDescription)\n")
    }
}

func reportSMART(matching bsdName: String?) {
    do {
        let drives = try DriveEnumerator().enumerate()
            .filter { !$0.isVirtual }
            .filter { bsdName == nil || $0.bsdName == bsdName }

        if drives.isEmpty {
            print(bsdName.map { "Không tìm thấy ổ \($0)." } ?? "Không tìm thấy ổ vật lý nào.")
            exit(1)
        }
        for drive in drives {
            switch drive.smartInterface {
            case .nvme:
                reportNVMe(drive)
            case .ata:
                reportATA(drive)
            case .unsupported:
                print("── \(drive.bsdName): \(drive.model) — SMART không khả dụng qua \(drive.interconnect)\n")
            }
        }
    } catch {
        FileHandle.standardError.write(Data("Lỗi: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

switch arguments.first {
case nil, "smart":
    reportSMART(matching: arguments.count > 1 ? arguments[1] : nil)
case "list":
    do {
        listDrives(try DriveEnumerator().enumerate())
    } catch {
        FileHandle.standardError.write(Data("Lỗi: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
case "help", "-h", "--help":
    printUsage()
default:
    printUsage()
    exit(2)
}
