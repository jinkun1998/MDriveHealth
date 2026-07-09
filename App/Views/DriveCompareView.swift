/*
 * DriveCompareView.swift — fleet overview table for all discovered drives.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import SwiftUI
import MDriveHealthCore

struct DriveCompareView: View {
    @Environment(DriveStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Tất cả ổ đĩa", systemImage: "list.bullet.rectangle")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text("\(store.visibleSnapshots.count) ổ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if store.visibleSnapshots.isEmpty {
                ContentUnavailableView(
                    "Chưa phát hiện ổ đĩa",
                    systemImage: "internaldrive",
                    description: Text("Bấm Làm mới để quét lại. Ổ USB không hỗ trợ SMART passthrough vẫn có thể xuất hiện nhưng không có chỉ số sức khoẻ."))
                    .frame(maxHeight: .infinity)
            } else {
                Table(store.visibleSnapshots) {
                    TableColumn("Ổ") { snapshot in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(snapshot.drive.model)
                                .lineLimit(1)
                            Text("\(snapshot.drive.bsdName) · \(snapshot.drive.interconnect)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .width(min: 220)

                    TableColumn("Sức khoẻ") { snapshot in
                        if let health = snapshot.health {
                            HealthBadge(rating: health.rating)
                                .controlSize(.small)
                        } else {
                            Text(snapshot.drive.smartInterface == .unsupported ? "SMART n/a" : "Chưa đọc")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .width(110)

                    TableColumn("Điểm") { snapshot in
                        Text(snapshot.health.map { "\($0.score)" } ?? "—")
                            .monospacedDigit()
                    }
                    .width(54)

                    TableColumn("Nhiệt") { snapshot in
                        Text(snapshot.reading?.temperatureCelsius.map { "\($0)°C" } ?? "—")
                            .monospacedDigit()
                    }
                    .width(64)

                    TableColumn("Lifetime") { snapshot in
                        Text(snapshot.health?.lifetimeLeftPercent.map { "\($0)%" } ?? "—")
                            .monospacedDigit()
                    }
                    .width(76)

                    TableColumn("Power-on") { snapshot in
                        Text(snapshot.reading?.powerOnHours.map(Format.hours) ?? "—")
                            .monospacedDigit()
                    }
                    .width(100)

                    TableColumn("Đã ghi") { snapshot in
                        Text(snapshot.reading?.bytesWritten.map(Format.bytes) ?? "—")
                            .monospacedDigit()
                    }
                    .width(100)

                    TableColumn("Lỗi") { snapshot in
                        if let reading = snapshot.reading {
                            let count = RiskAdvisor.dangerousCounter(reading: reading)
                            Text("\(count)")
                                .monospacedDigit()
                                .foregroundStyle(count > 0 ? .red : .secondary)
                        } else {
                            Text("—")
                        }
                    }
                    .width(56)
                }
            }
        }
        .padding()
    }
}
