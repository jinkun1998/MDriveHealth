/*
 * DeviceInfoTab.swift — identify/registry details for a drive.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import SwiftUI
import MDriveHealthCore

struct DeviceInfoTab: View {
    let snapshot: DriveSnapshot
    @State private var bridge: USBBridgeInfo?
    @State private var trimEnabled: Bool?

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
        if let trimEnabled {
            result.append(("TRIM/Deallocate", trimEnabled
                ? String(localized: "trim.on", defaultValue: "Đang bật")
                : String(localized: "trim.off", defaultValue: "Đang tắt")))
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
            if trimEnabled == false, snapshot.drive.isSolidState,
               snapshot.drive.smartInterface == .ata {
                Label("TRIM đang tắt cho SSD SATA này — hiệu năng và tuổi thọ sẽ giảm dần. Bật bằng Terminal: sudo trimforce enable (máy sẽ khởi động lại).",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if let bridge {
                Section("Cầu nối USB") {
                    ForEach(bridgeRows(bridge), id: \.0) { name, value in
                        HStack {
                            Text(LocalizedStringKey(name))
                            Spacer()
                            Text(value)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    if bridge.linkSpeedMbps == 480 {
                        Label("Đang chạy ở 480 Mb/s (USB 2.0) — kiểm tra lại cáp và cổng: ổ này có thể nhanh hơn nhiều với cáp/cổng USB 3.",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    if snapshot.drive.smartInterface == .unsupported {
                        Label("Chip cầu nối này không passthrough SMART — macOS không có driver SAT nên không app nào đọc được chỉ số sức khoẻ qua nó. Vẫn đo được tốc độ và kiểm tra dung lượng thật ở tab Tốc độ.",
                              systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    }
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
        .task(id: snapshot.id) {
            // Reset first so a drive switch never shows the previous drive's
            // bridge/TRIM; drop the result if this task was cancelled by a
            // newer switch while we awaited.
            bridge = nil
            trimEnabled = nil
            bridge = USBBridgeReader.bridgeInfo(
                forDriveRegistryEntryID: snapshot.drive.registryEntryID)
            let trim = await TrimStatusReader.trimSupport(bsdName: snapshot.drive.bsdName)
            if !Task.isCancelled { trimEnabled = trim }
        }
    }

    private func bridgeRows(_ bridge: USBBridgeInfo) -> [(String, String)] {
        var rows: [(String, String)] = []
        if let vendor = bridge.vendorName { rows.append(("Hãng cầu nối", vendor)) }
        if let product = bridge.productName { rows.append(("Chip/enclosure", product)) }
        if let vid = bridge.vendorID, let pid = bridge.productID {
            rows.append(("Vendor/Product ID",
                         String(format: "0x%04X / 0x%04X", vid, pid)))
        }
        if let mbps = bridge.linkSpeedMbps {
            rows.append(("Tốc độ link thực tế", linkSpeedLabel(mbps)))
        }
        rows.append(("Chế độ truyền", bridge.usesUAS
            ? "UASP (USB Attached SCSI)"
            : String(localized: "usb.bot", defaultValue: "BOT (Bulk-Only, chậm hơn UASP)")))
        return rows
    }

    private func linkSpeedLabel(_ mbps: Int) -> String {
        switch mbps {
        case ..<480: return "\(mbps) Mb/s (USB 1.x)"
        case 480: return "480 Mb/s (USB 2.0)"
        case 5_000: return "5 Gb/s (USB 3.x Gen 1)"
        case 10_000: return "10 Gb/s (USB 3.x Gen 2)"
        case 20_000: return "20 Gb/s (USB 3.2 Gen 2x2)"
        default: return "\(mbps / 1000) Gb/s"
        }
    }
}
