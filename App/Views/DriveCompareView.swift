/*
 * DriveCompareView.swift — fleet overview table for all discovered drives.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import SwiftUI
import Charts
import MDriveHealthCore

/// Flat, sortable projection of one drive for the fleet table. Missing
/// numbers sort as -1 so drives without SMART sink to the bottom.
private struct FleetRow: Identifiable {
    let snapshot: DriveSnapshot

    var id: UInt64 { snapshot.id }
    var model: String { snapshot.drive.model }
    var score: Int { snapshot.health?.score ?? -1 }
    var temperature: Int { snapshot.reading?.temperatureCelsius ?? -1 }
    var lifetime: Int { snapshot.health?.lifetimeLeftPercent ?? -1 }
    var powerOnHours: Int {
        guard let hours = snapshot.reading?.powerOnHours else { return -1 }
        return Int(clamping: hours)
    }
    var bytesWritten: Int {
        guard let bytes = snapshot.reading?.bytesWritten else { return -1 }
        return Int(clamping: bytes)
    }
    var defects: Int {
        guard let reading = snapshot.reading else { return -1 }
        return Int(clamping: reading.dangerousDefectTotal)
    }
}

struct DriveCompareView: View {
    @Environment(DriveStore.self) private var store
    @State private var sortOrder = [KeyPathComparator(\FleetRow.model)]
    @State private var selectedID: UInt64?
    /// 24h temperature series per drive for the sparkline column.
    @State private var temperatureSeries: [UInt64: [Double]] = [:]

    private var rows: [FleetRow] {
        store.visibleSnapshots.map(FleetRow.init).sorted(using: sortOrder)
    }

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
                Table(rows, selection: $selectedID, sortOrder: $sortOrder) {
                    TableColumn("Ổ", value: \.model) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.snapshot.drive.model)
                                .lineLimit(1)
                            Text("\(row.snapshot.drive.bsdName) · \(row.snapshot.drive.interconnect)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .width(min: 200)

                    TableColumn("Sức khoẻ", value: \.score) { row in
                        if let health = row.snapshot.health {
                            HealthBadge(rating: health.rating)
                                .controlSize(.small)
                        } else {
                            Text(row.snapshot.drive.smartInterface == .unsupported
                                 ? "SMART n/a" : "Chưa đọc")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .width(110)

                    TableColumn("Điểm", value: \.score) { row in
                        Text(row.score >= 0 ? "\(row.score)" : "—")
                            .monospacedDigit()
                    }
                    .width(54)

                    TableColumn("Nhiệt", value: \.temperature) { row in
                        Text(row.temperature >= 0 ? "\(row.temperature)°C" : "—")
                            .monospacedDigit()
                    }
                    .width(64)

                    TableColumn("24h") { row in
                        if let series = temperatureSeries[row.id], series.count > 1 {
                            TemperatureSparkline(values: series)
                        } else {
                            Text(verbatim: "—")
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .width(88)

                    TableColumn("Lifetime", value: \.lifetime) { row in
                        Text(row.lifetime >= 0 ? "\(row.lifetime)%" : "—")
                            .monospacedDigit()
                    }
                    .width(76)

                    TableColumn("Power-on", value: \.powerOnHours) { row in
                        Text(row.snapshot.reading?.powerOnHours.map(Format.hours) ?? "—")
                            .monospacedDigit()
                    }
                    .width(100)

                    TableColumn("Đã ghi", value: \.bytesWritten) { row in
                        Text(row.snapshot.reading?.bytesWritten.map(Format.bytes) ?? "—")
                            .monospacedDigit()
                    }
                    .width(100)

                    TableColumn("Lỗi", value: \.defects) { row in
                        Text(row.defects >= 0 ? "\(row.defects)" : "—")
                            .monospacedDigit()
                            .foregroundStyle(row.defects > 0 ? .red : .secondary)
                    }
                    .width(56)
                }
                .contextMenu(forSelectionType: UInt64.self) { ids in
                    Button("Mở chi tiết") {
                        openDrive(ids.first)
                    }
                } primaryAction: { ids in
                    // Double-click a row → jump to the drive's detail page.
                    openDrive(ids.first)
                }
            }
        }
        .padding()
        .task(id: store.lastRefresh) { await loadSparklines() }
    }

    private func openDrive(_ id: UInt64?) {
        guard let id else { return }
        store.pendingSelection = id
    }

    private func loadSparklines() async {
        guard let history = store.history else { return }
        let drives = store.visibleSnapshots.map(\.drive)
        temperatureSeries = await Task.detached(priority: .utility) {
            () -> [UInt64: [Double]] in
            var series: [UInt64: [Double]] = [:]
            let since = Date().addingTimeInterval(-24 * 3_600)
            for drive in drives {
                let key = HistoryStore.driveKey(for: drive)
                let points = (try? history.history(driveKey: key, since: since,
                                                   bucketInterval: 1_800)) ?? []
                series[drive.id] = points.compactMap { $0.temperatureC.map(Double.init) }
            }
            return series
        }.value
    }
}

/// Axis-less mini chart for a table cell.
private struct TemperatureSparkline: View {
    let values: [Double]

    var body: some View {
        Chart(Array(values.enumerated()), id: \.offset) { item in
            LineMark(x: .value("i", item.offset),
                     y: .value("t", item.element))
                .lineStyle(StrokeStyle(lineWidth: 1.2))
                .foregroundStyle((values.max() ?? 0) >= 60 ? .orange : .teal)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: (values.min() ?? 0) - 2...(values.max() ?? 1) + 2)
        .frame(width: 72, height: 22)
        .accessibilityLabel(Text("Nhiệt độ 24 giờ"))
    }
}
