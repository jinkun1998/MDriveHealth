/*
 * OverviewTab.swift — per-drive dashboard: gauges, quick stats, issues.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import SwiftUI
import MDriveHealthCore

struct OverviewTab: View {
    let snapshot: DriveSnapshot
    @Environment(DriveStore.self) private var store
    @State private var wearTrend: WearTrendEstimate?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                riskSummary

                if let error = snapshot.lastError {
                    errorBanner(staleAwareMessage(for: error))
                } else if snapshot.drive.smartInterface == .unsupported {
                    unsupportedBanner
                }

                if let ioErrors = store.ioErrorCounts[snapshot.drive.bsdName],
                   ioErrors > 0 {
                    Label("\(ioErrors) lỗi I/O liên quan tới \(snapshot.drive.bsdName) trong kernel log 24 giờ qua — dấu hiệu cần chú ý ngay cả khi SMART chưa báo.",
                          systemImage: "exclamationmark.triangle.fill")
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }

                if let health = snapshot.health, let reading = snapshot.reading {
                    gaugeRow(health: health, reading: reading)
                    // Capacity fills the empty cells left by the last stat row.
                    statsAndCapacity(reading: reading)
                } else if !snapshot.volumes.isEmpty {
                    // No SMART reading (e.g. USB) — still show capacity.
                    capacitySection
                }

                if let health = snapshot.health {
                    issuesSection(health: health)
                }

                if let updated = snapshot.lastUpdated {
                    Text(String(localized: "overview.updatedAt",
                                defaultValue: "Cập nhật \(updated.formatted(date: .omitted, time: .shortened))"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: snapshot.lastUpdated) { await loadWearTrend() }
    }

    @ViewBuilder
    private var riskSummary: some View {
        let advice = RiskAdvisor.advice(for: snapshot)
        if advice.level > .healthy {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: advice.level.systemImage)
                        .font(.title2)
                        .foregroundStyle(advice.level.color)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(advice.title)
                            .font(.headline)
                        Text(advice.message)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !advice.actions.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("risk.actions.title")
                            .font(.subheadline.weight(.semibold))
                        ForEach(Array(advice.actions.enumerated()), id: \.offset) { _, action in
                            Label(action, systemImage: "checklist.checked")
                                .font(.callout)
                        }
                    }
                    .padding(.leading, 38)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(advice.level.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
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
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [health.rating.color.opacity(0.14),
                         health.rating.color.opacity(0.03)],
                startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(health.rating.color.opacity(0.22), lineWidth: 1))
    }

    private struct StatItem: Identifiable {
        let id: String              // icon name — unique per card, stable across renders
        let title: LocalizedStringKey
        let value: String
    }

    private func statItems(reading: DriveReading) -> [StatItem] {
        var items: [StatItem] = []
        if let hours = reading.powerOnHours {
            items.append(.init(id: "clock", title: "Thời gian hoạt động",
                               value: Format.hours(hours)))
        }
        if let cycles = reading.powerCycles {
            items.append(.init(id: "power", title: "Số lần bật nguồn", value: "\(cycles)"))
        }
        if let written = reading.bytesWritten {
            items.append(.init(id: "square.and.pencil", title: "Tổng dữ liệu đã ghi",
                               value: Format.bytes(written)))
        }
        if case .nvme(let nvme) = reading {
            items.append(.init(id: "doc.text.magnifyingglass", title: "Tổng dữ liệu đã đọc",
                               value: Format.bytes(nvme.smart.bytesRead)))
            items.append(.init(id: "bolt.slash", title: "Tắt nguồn đột ngột",
                               value: "\(nvme.smart.unsafeShutdowns)"))
            items.append(.init(id: "externaldrive.badge.plus", title: "Spare còn lại",
                               value: "\(nvme.smart.availableSpare)%"))
        }
        if case .ata(let ata) = reading, let family = ata.driveFamily {
            items.append(.init(id: "tag", title: "Dòng ổ (drivedb)", value: family))
        }
        if let rate = wearTrend?.bytesWrittenPerDay, rate > 0 {
            items.append(.init(id: "chart.line.uptrend.xyaxis", title: "Ghi trung bình mỗi ngày",
                               value: String(localized: "format.perDay",
                                             defaultValue: "\(Format.bytes(UInt64(rate)))/ngày")))
        }
        if let exhaustion = wearTrend?.estimatedExhaustionDate {
            items.append(.init(id: "hourglass", title: "Dự kiến cạn SSD lifetime",
                               value: exhaustion.formatted(.dateTime.month(.wide).year())))
        }
        return items
    }

    /// Stat cards in a fixed 3-column grid; the capacity bar(s) fill the empty
    /// cells left in the last row (and spill to full-width rows below when
    /// there's more than one volume group or the last row is already full).
    private func statsAndCapacity(reading: DriveReading) -> some View {
        let stats = statItems(reading: reading)
        let groups = VolumeUsageReader.capacityGroups(snapshot.volumes)
        let columns = 3
        let fullRows = stats.count / columns
        let remainder = stats.count % columns
        // First capacity group tucks into the trailing gap when there is one.
        let inlineGroup = remainder > 0 ? groups.first : nil
        let belowGroups = inlineGroup != nil ? Array(groups.dropFirst()) : groups

        return Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            ForEach(0..<fullRows, id: \.self) { row in
                GridRow {
                    ForEach(0..<columns, id: \.self) { col in
                        statCard(stats[row * columns + col])
                    }
                }
            }
            if remainder > 0 {
                GridRow {
                    ForEach(0..<remainder, id: \.self) { col in
                        statCard(stats[fullRows * columns + col])
                    }
                    if let inlineGroup {
                        capacityCard(inlineGroup).gridCellColumns(columns - remainder)
                    } else {
                        Color.clear.gridCellColumns(columns - remainder)
                    }
                }
            }
            ForEach(belowGroups) { group in
                GridRow {
                    capacityCard(group).gridCellColumns(columns)
                }
            }
        }
    }

    private func statCard(_ item: StatItem) -> some View {
        StatCard(title: item.title, value: item.value, systemImage: item.id)
    }

    private func capacityCard(_ group: VolumeCapacityGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: snapshot.drive.isInternal
                      ? "internaldrive" : "externaldrive")
                    .font(.caption)
                Text(verbatim: group.displayName)
                    .font(.caption)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(verbatim: "\(Format.bytes(group.usedBytes)) / \(Format.bytes(group.totalBytes)) (\(Int(group.usedFraction * 100))%)")
                    .font(.caption)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
            ProgressView(value: group.usedFraction)
                .tint(group.usedFraction >= 0.95 ? .red
                      : group.usedFraction >= 0.85 ? .orange : .accentColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .cardBackground()
        .accessibilityElement(children: .combine)
    }

    private var capacitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Dung lượng")
                .font(.headline)
            ForEach(VolumeUsageReader.capacityGroups(snapshot.volumes)) { group in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(verbatim: group.displayName)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        Spacer()
                        Text(verbatim: "\(Format.bytes(group.usedBytes)) / \(Format.bytes(group.totalBytes)) (\(Int(group.usedFraction * 100))%)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    ProgressView(value: group.usedFraction)
                        .tint(group.usedFraction >= 0.95 ? .red
                              : group.usedFraction >= 0.85 ? .orange : .accentColor)
                }
                .padding(10)
                .background(.quaternary.opacity(0.35),
                            in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func loadWearTrend() async {
        guard let history = store.history, snapshot.health != nil else { return }
        let key = HistoryStore.driveKey(for: snapshot.drive)
        let since = Date().addingTimeInterval(-90 * 86_400)
        let points = (try? await history.history(driveKey: key, since: since,
                                                 bucketInterval: 3_600)) ?? []
        wearTrend = WearTrend.estimate(from: points)
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

    /// When old data is carried over after a failed probe, say so — the
    /// gauges below reflect the previous successful reading.
    private func staleAwareMessage(for error: String) -> String {
        guard snapshot.isStale, let lastUpdated = snapshot.lastUpdated else {
            return error
        }
        let time = lastUpdated.formatted(date: .abbreviated, time: .shortened)
        return String(localized: "overview.stale.banner",
                      defaultValue: "Lần đọc mới nhất thất bại: \(error) — đang hiển thị dữ liệu đọc lúc \(time).")
    }

    private var unsupportedBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("SMART không khả dụng cho ổ này", systemImage: "info.circle")
                .font(.headline)
            Text("macOS không cho phép đọc SMART qua cầu USB mass-storage — đây là hạn chế của hệ điều hành, áp dụng cho mọi ứng dụng. Ổ cắm qua Thunderbolt hoặc khe NVMe/SATA nội bộ vẫn đọc được bình thường.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label("Gợi ý: thử cáp/hộp ổ hỗ trợ SMART passthrough, hoặc theo dõi lỗi I/O nếu ổ hay mất kết nối.",
                  systemImage: "lightbulb")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}
