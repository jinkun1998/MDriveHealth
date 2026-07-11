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
    @State private var hoverDate: Date?
    /// Materialized from `points` on load/metric change — chartXSelection
    /// re-evaluates body on every pointer move while scrubbing, so this must
    /// not be recomputed per frame.
    @State private var chartData: [(date: Date, value: Double)] = []

    private var timeLabel: String { String(localized: "chart.axis.time", defaultValue: "Thời gian") }
    private var markerLabel: String { String(localized: "chart.axis.marker", defaultValue: "Mốc") }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Chỉ số", selection: $metric) {
                    ForEach(Metric.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .frame(maxWidth: 220)
                Picker("Khoảng", selection: $range) {
                    ForEach(Range.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
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
                    description: Text("Dữ liệu được ghi lại mỗi lần đọc SMART. Hãy để app chạy nền để tích luỹ lịch sử."))
                    .frame(maxHeight: .infinity)
            } else {
                Chart {
                    ForEach(chartData, id: \.date) { item in
                        LineMark(x: .value(timeLabel, item.date),
                                 y: .value(metric.rawValue, item.value))
                            .interpolationMethod(.monotone)
                        AreaMark(x: .value(timeLabel, item.date),
                                 y: .value(metric.rawValue, item.value))
                            .foregroundStyle(.linearGradient(
                                colors: [.accentColor.opacity(0.25), .clear],
                                startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                    }
                    ForEach(trendEvents) { event in
                        RuleMark(x: .value(markerLabel, event.date))
                            .foregroundStyle(event.color.opacity(0.65))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .annotation(position: .top, alignment: .leading) {
                                Text(event.title)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(event.color)
                            }
                    }
                    if let hovered = hoveredPoint {
                        RuleMark(x: .value(timeLabel, hovered.date))
                            .foregroundStyle(.secondary.opacity(0.6))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                        PointMark(x: .value(timeLabel, hovered.date),
                                  y: .value(metric.rawValue, hovered.value))
                            .symbolSize(60)
                            .annotation(
                                position: .top, spacing: 6,
                                overflowResolution: .init(x: .fit(to: .chart),
                                                          y: .disabled)
                            ) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(formattedValue(hovered.value))
                                        .font(.caption.weight(.bold))
                                        .monospacedDigit()
                                    Text(hovered.date.formatted(
                                        date: .abbreviated, time: .shortened))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(6)
                                .background(.regularMaterial,
                                            in: RoundedRectangle(cornerRadius: 6))
                            }
                    }
                }
                .chartYAxisLabel(yLabel)
                // Percent metrics anchor at 0; measurements (temp, TB, counts)
                // zoom to their actual range so small trends stay visible.
                .chartYScale(domain: .automatic(
                    includesZero: metric == .score || metric == .lifetime))
                .chartXSelection(value: $hoverDate)
                .frame(maxHeight: .infinity)
            }
        }
        .padding()
        .task(id: "\(snapshot.id)-\(range.rawValue)") { await reload() }
        .onChange(of: store.lastRefresh) { Task { await reload() } }
        .onChange(of: metric) { rebuildChartData() }
    }

    private func rebuildChartData() {
        chartData = points.compactMap { point in
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
        case .defects: return String(localized: "chart.unit.count", defaultValue: "số lượng")
        }
    }

    /// Data point nearest to the hovered X position.
    private var hoveredPoint: (date: Date, value: Double)? {
        guard let hoverDate else { return nil }
        return chartData.min {
            abs($0.date.timeIntervalSince(hoverDate))
                < abs($1.date.timeIntervalSince(hoverDate))
        }
    }

    private func formattedValue(_ value: Double) -> String {
        switch metric {
        case .temperature: return "\(Int(value))°C"
        case .score: return "\(Int(value))/100"
        case .lifetime: return "\(Int(value))%"
        case .written: return String(format: "%.2f TB", value)
        case .defects: return "\(Int(value))"
        }
    }

    private struct TrendEvent: Identifiable {
        let id = UUID()
        let date: Date
        let title: LocalizedStringKey
        let color: Color
    }

    private var trendEvents: [TrendEvent] {
        guard points.count > 1 else { return [] }
        var events: [TrendEvent] = []
        var previous = points[0]
        for point in points.dropFirst() {
            if let old = previous.defectCount, let new = point.defectCount, new > old {
                events.append(.init(date: point.capturedAt, title: "Lỗi tăng", color: .red))
            }
            if let temp = point.temperatureC, temp >= 70,
               (previous.temperatureC ?? 0) < 70 {
                events.append(.init(date: point.capturedAt, title: "Nóng", color: .orange))
            }
            if let old = previous.healthScore, let new = point.healthScore, old - new >= 5 {
                events.append(.init(date: point.capturedAt, title: "Health giảm", color: .orange))
            }
            previous = point
        }
        return Array(events.prefix(12))
    }

    private func reload() async {
        guard let history = store.history else { return }
        let key = HistoryStore.driveKey(for: snapshot.drive)
        let since = Date().addingTimeInterval(-range.interval)
        let bucket = max(1, range.interval / 1_000)
        points = (try? await history.history(
            driveKey: key, since: since, bucketInterval: bucket)) ?? []
        rebuildChartData()
    }
}
