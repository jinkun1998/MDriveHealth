/*
 * OverviewTab.swift — per-drive dashboard: gauges, quick stats, issues.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import SwiftUI
import MDriveHealthCore

struct OverviewTab: View {
    let snapshot: DriveSnapshot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let error = snapshot.lastError {
                    errorBanner(error)
                } else if snapshot.drive.smartInterface == .unsupported {
                    unsupportedBanner
                }

                if let health = snapshot.health, let reading = snapshot.reading {
                    gaugeRow(health: health, reading: reading)
                    quickStats(reading: reading)
                    issuesSection(health: health)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func gaugeRow(health: HealthReport, reading: DriveReading) -> some View {
        HStack(spacing: 28) {
            RingGauge(
                value: Double(health.score) / 100,
                label: "\(health.score)",
                caption: "Sức khoẻ tổng thể",
                color: health.rating.color
            )
            if let lifetime = health.lifetimeLeftPercent {
                RingGauge(
                    value: Double(lifetime) / 100,
                    label: "\(lifetime)%",
                    caption: "SSD lifetime còn lại",
                    color: lifetime > 20 ? .blue : .orange
                )
            }
            if let temp = reading.temperatureCelsius {
                RingGauge(
                    value: min(1, Double(temp) / 90),
                    label: "\(temp)°C",
                    caption: "Nhiệt độ",
                    color: temp >= 70 ? .red : temp >= 55 ? .orange : .teal
                )
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func quickStats(reading: DriveReading) -> some View {
        let columns = [GridItem(.adaptive(minimum: 160), spacing: 10)]
        LazyVGrid(columns: columns, spacing: 10) {
            if let hours = reading.powerOnHours {
                StatCard(title: "Thời gian hoạt động", value: Format.hours(hours),
                         systemImage: "clock")
            }
            if let cycles = reading.powerCycles {
                StatCard(title: "Số lần bật nguồn", value: "\(cycles)",
                         systemImage: "power")
            }
            if let written = reading.bytesWritten {
                StatCard(title: "Tổng dữ liệu đã ghi", value: Format.bytes(written),
                         systemImage: "square.and.pencil")
            }
            if case .nvme(let nvme) = reading {
                StatCard(title: "Tổng dữ liệu đã đọc", value: Format.bytes(nvme.smart.bytesRead),
                         systemImage: "doc.text.magnifyingglass")
                StatCard(title: "Tắt nguồn đột ngột", value: "\(nvme.smart.unsafeShutdowns)",
                         systemImage: "bolt.slash")
                StatCard(title: "Spare còn lại", value: "\(nvme.smart.availableSpare)%",
                         systemImage: "externaldrive.badge.plus")
            }
            if case .ata(let ata) = reading, let family = ata.driveFamily {
                StatCard(title: "Dòng ổ (drivedb)", value: family,
                         systemImage: "tag")
            }
        }
    }

    @ViewBuilder
    private func issuesSection(health: HealthReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Chỉ báo sức khoẻ")
                .font(.headline)
            if health.issues.isEmpty {
                Label("Không phát hiện vấn đề nào — ổ đĩa hoạt động bình thường.",
                      systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .padding(.vertical, 4)
            } else {
                ForEach(health.issues) { issue in
                    HStack(alignment: .top, spacing: 10) {
                        Circle()
                            .fill(issue.severity.color)
                            .frame(width: 10, height: 10)
                            .padding(.top, 5)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(issue.title).font(.callout.weight(.semibold))
                                Text(issue.severity.displayName)
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(issue.severity.color.opacity(0.15),
                                                in: Capsule())
                                    .foregroundStyle(issue.severity.color)
                            }
                            Text(issue.detail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.35),
                                in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
    }

    private var unsupportedBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("SMART không khả dụng cho ổ này", systemImage: "info.circle")
                .font(.headline)
            Text("macOS không cho phép đọc SMART qua cầu USB mass-storage. " +
                 "Hạn chế này áp dụng cho mọi ứng dụng (kể cả DriveDX khi chưa cài driver riêng). " +
                 "Ổ cắm qua Thunderbolt hoặc khe NVMe/SATA nội bộ vẫn đọc được bình thường.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}
