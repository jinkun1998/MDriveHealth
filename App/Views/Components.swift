/*
 * Components.swift — shared UI pieces: health badge, rings, stat cards.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import SwiftUI
import MDriveHealthCore

extension HealthRating {
    var displayName: String {
        switch self {
        case .good: return String(localized: "rating.good", defaultValue: "Tốt")
        case .ok: return String(localized: "rating.ok", defaultValue: "Ổn")
        case .warning: return String(localized: "rating.warning", defaultValue: "Cảnh báo")
        case .failing: return String(localized: "rating.failing", defaultValue: "Đang hỏng")
        case .failed: return String(localized: "rating.failed", defaultValue: "Hỏng")
        }
    }

    var color: Color {
        switch self {
        case .good: return .green
        case .ok: return Color(red: 0.55, green: 0.75, blue: 0.1)
        case .warning: return .orange
        case .failing: return .red
        case .failed: return Color(red: 0.6, green: 0, blue: 0.05)
        }
    }

    var systemImage: String {
        switch self {
        case .good: return "checkmark.circle.fill"
        case .ok: return "checkmark.circle"
        case .warning: return "exclamationmark.triangle.fill"
        case .failing: return "exclamationmark.octagon.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }
}

extension IssueSeverity {
    var color: Color {
        switch self {
        case .info: return .gray
        case .advisory: return .blue
        case .warning: return .orange
        case .critical: return .red
        }
    }

    var displayName: String {
        switch self {
        case .info: return String(localized: "severity.info", defaultValue: "Thông tin")
        case .advisory: return String(localized: "severity.advisory", defaultValue: "Lưu ý")
        case .warning: return String(localized: "severity.warning", defaultValue: "Cảnh báo")
        case .critical: return String(localized: "severity.critical", defaultValue: "Nghiêm trọng")
        }
    }
}

struct HealthBadge: View {
    let rating: HealthRating

    var body: some View {
        Label(rating.displayName, systemImage: rating.systemImage)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(rating.color, in: Capsule())
            .accessibilityLabel(Text(verbatim: rating.displayName))
    }
}

/// Circular gauge for scores/percentages.
struct RingGauge: View {
    let value: Double // 0...1
    let label: String
    let caption: LocalizedStringKey
    var color: Color = .green

    @State private var animatedValue: Double = 0

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: max(0.02, min(1, animatedValue)))
                    .stroke(color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(label)
                    .font(.title2.weight(.bold))
                    .monospacedDigit()
            }
            .frame(width: 92, height: 92)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(caption))
        .accessibilityValue(Text(label))
        .onAppear {
            withAnimation(.easeOut(duration: 0.7)) { animatedValue = value }
        }
        .onChange(of: value) { _, newValue in
            withAnimation(.easeOut(duration: 0.4)) { animatedValue = newValue }
        }
    }
}

struct StatCard: View {
    let title: LocalizedStringKey
    let value: String
    var systemImage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage).font(.caption)
                }
                Text(title).font(.caption)
            }
            .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .cardBackground()
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// Shared card chrome: soft fill plus a hairline border — the border is
    /// what keeps card edges visible in dark mode, where a faint .quaternary
    /// fill alone melts into the window background.
    func cardBackground(cornerRadius: CGFloat = 10) -> some View {
        self
            .background(.quaternary.opacity(0.35),
                        in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
    }
}

enum Format {
    /// Shared instance — Format is only called from the main actor, and
    /// formatter construction is a classic per-frame allocation sink (bytes()
    /// runs dozens of times per render pass).
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    static func bytes(_ value: UInt64) -> String {
        byteFormatter.string(fromByteCount: Int64(clamping: value))
    }

    static func hours(_ value: UInt64) -> String {
        if value >= 48 {
            return String(localized: "format.hours.days",
                          defaultValue: "\(value) giờ (≈\(value / 24) ngày)")
        }
        return String(localized: "format.hours", defaultValue: "\(value) giờ")
    }

    static func minutes(_ value: UInt64) -> String {
        String(localized: "format.minutes", defaultValue: "\(Int(clamping: value)) phút")
    }

    /// Throughput in decimal MB/s (1e6) — the disk-benchmark convention.
    /// locale-aware so vi gets its decimal comma like every other number.
    static func speed(_ bytesPerSecond: Double) -> String {
        String(format: "%.1f MB/s", locale: .current, bytesPerSecond / 1e6)
    }

    static func iops(_ value: Double) -> String {
        value >= 1000
            ? String(format: "%.1fk IOPS", locale: .current, value / 1000)
            : String(format: "%.0f IOPS", locale: .current, value)
    }
}
