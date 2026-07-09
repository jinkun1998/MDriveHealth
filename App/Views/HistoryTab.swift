/*
 * HistoryTab.swift — trend charts (temperature, health, wear, defects).
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import SwiftUI
import Charts
import MDriveHealthCore

struct HistoryTab: View {
    let snapshot: DriveSnapshot
    @Environment(DriveStore.self) private var store

    private enum Metric: String, CaseIterable, Identifiable {
        case temperature = "Nhiệt độ"
        case score = "Điểm sức khoẻ"
        case lifetime = "SSD lifetime"
        case written = "Dữ liệu đã ghi"
        case defects = "Lỗi/Sector hỏng"
        var id: String { rawValue }
    }

    private enum Range: String, CaseIterable, Identifiable {
        case day = "24 giờ"
        case week = "7 ngày"
        case month = "30 ngày"
        case year = "1 năm"
        var id: String { rawValue }

        var interval: TimeInterval {
            switch self {
            case .day: return 86_400
            case .week: return 7 * 86_400
            case .month: return 30 * 86_400
            case .year: return 365 * 86_400
            }
        }
    }

    @State private var metric: Metric = .temperature
    @State private var range: Range = .week
    @State private var points: [HistoryPoint] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Chỉ số", selection: $metric) {
                    ForEach(Metric.allCases) { Text($0.rawValue).tag($0) }
                }
                .frame(maxWidth: 220)
                Picker("Khoảng", selection: $range) {
                    ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
                Spacer()
                Text("\(points.count) điểm dữ liệu")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if chartData.isEmpty {
                ContentUnavailableView(
                    "Chưa có dữ liệu lịch sử",
                    systemImage: "chart.xyaxis.line",
                    description: Text("Dữ liệu được ghi lại mỗi lần đọc SMART. " +
                                      "Hãy để app chạy nền để tích luỹ lịch sử."))
                    .frame(maxHeight: .infinity)
            } else {
                Chart(chartData, id: \.date) { item in
                    LineMark(x: .value("Thời gian", item.date),
                             y: .value(metric.rawValue, item.value))
                        .interpolationMethod(.monotone)
                    AreaMark(x: .value("Thời gian", item.date),
                             y: .value(metric.rawValue, item.value))
                        .foregroundStyle(.linearGradient(
                            colors: [.accentColor.opacity(0.25), .clear],
                            startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                }
                .chartYAxisLabel(yLabel)
                .frame(maxHeight: .infinity)
            }
        }
        .padding()
        .task(id: "\(snapshot.id)-\(range.rawValue)") { reload() }
        .onChange(of: store.lastRefresh) { reload() }
    }

    private var chartData: [(date: Date, value: Double)] {
        points.compactMap { point in
            let value: Double?
            switch metric {
            case .temperature: value = point.temperatureC.map(Double.init)
            case .score: value = point.healthScore.map(Double.init)
            case .lifetime: value = point.lifetimeLeftPercent.map(Double.init)
            case .written: value = point.bytesWritten.map { Double($0) / 1e12 } // TB
            case .defects: value = point.defectCount.map(Double.init)
            }
            guard let value else { return nil }
            return (point.capturedAt, value)
        }
    }

    private var yLabel: String {
        switch metric {
        case .temperature: return "°C"
        case .score, .lifetime: return "%"
        case .written: return "TB"
        case .defects: return "số lượng"
        }
    }

    private func reload() {
        guard let history = store.history else { return }
        let key = HistoryStore.driveKey(for: snapshot.drive)
        points = (try? history.history(
            driveKey: key, since: Date().addingTimeInterval(-range.interval))) ?? []
    }
}
