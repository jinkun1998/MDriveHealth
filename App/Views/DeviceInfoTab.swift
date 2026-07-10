/*
 * DeviceInfoTab.swift — identify/registry details for a drive.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import SwiftUI
import MDriveHealthCore

struct DeviceInfoTab: View {
    let snapshot: DriveSnapshot

    private var rows: [(String, String)] {
        var result: [(String, String)] = [
            ("Model", snapshot.drive.model),
            ("BSD name", snapshot.drive.bsdName),
            ("Dung lượng", Format.bytes(snapshot.drive.sizeBytes)),
            ("Giao tiếp", snapshot.drive.interconnect),
            ("Vị trí", snapshot.drive.location == "Internal"
                ? String(localized: "device.internal", defaultValue: "Trong máy")
                : snapshot.drive.location),
            ("Loại", snapshot.drive.isSolidState
                ? String(localized: "device.ssd", defaultValue: "SSD (thể rắn)")
                : String(localized: "device.hdd", defaultValue: "HDD (cơ)")),
        ]
        if let serial = snapshot.drive.serialNumber {
            result.append(("Số serial", serial))
        }
        if let firmware = snapshot.drive.firmwareRevision {
            result.append(("Firmware (IOKit)", firmware))
        }
        switch snapshot.reading {
        case .nvme(let reading):
            let c = reading.controller
            result.append(("Model (NVMe identify)", c.model))
            result.append(("Serial (NVMe identify)", c.serialNumber))
            result.append(("Firmware (NVMe identify)", c.firmwareRevision))
            if c.ieeeOUI != "00-00-00" {
                result.append(("IEEE OUI", c.ieeeOUI))
            }
            if let version = c.specVersion {
                result.append(("Chuẩn NVMe", version))
            }
            if c.warningTempKelvin > 0 {
                result.append(("Ngưỡng nhiệt cảnh báo", "\(Int(c.warningTempKelvin) - 273)°C"))
            }
            if c.criticalTempKelvin > 0 {
                result.append(("Ngưỡng nhiệt nguy hiểm", "\(Int(c.criticalTempKelvin) - 273)°C"))
            }
            result.append(("Số namespace", "\(c.namespaceCount)"))
        case .ata(let reading):
            if let identify = reading.identify {
                result.append(("Model (IDENTIFY)", identify.model))
                result.append(("Serial (IDENTIFY)", identify.serialNumber))
                result.append(("Firmware (IDENTIFY)", identify.firmwareRevision))
                if let rpm = identify.rpm {
                    result.append(("Tốc độ quay", "\(rpm) rpm"))
                }
            }
            if let family = reading.driveFamily {
                result.append(("Dòng ổ (drivedb)", family))
            }
            if let overall = reading.overallFailurePredicted {
                result.append(("SMART overall status", overall ? "FAILING" : "PASSED"))
            }
        case nil:
            break
        }
        if let updated = snapshot.lastUpdated {
            result.append(("Cập nhật lần cuối",
                           updated.formatted(date: .abbreviated, time: .standard)))
        }
        return result
    }

    var body: some View {
        List {
            ForEach(rows, id: \.0) { name, value in
                HStack {
                    // Keys are the Vietnamese literals; the string catalog
                    // supplies the English translations.
                    Text(LocalizedStringKey(name))
                    Spacer()
                    Text(value)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
            }
            if !snapshot.volumes.isEmpty {
                Section("Volume đã mount") {
                    ForEach(snapshot.volumes) { volume in
                        HStack {
                            Text(verbatim: volume.name)
                            Spacer()
                            Text(verbatim: "\(volume.bsdName) · \(volume.mountPoint)")
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }
}
