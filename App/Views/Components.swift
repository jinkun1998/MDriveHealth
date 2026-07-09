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
    }
}

/// Circular gauge for scores/percentages, DriveDX-style.
struct RingGauge: View {
    let value: Double // 0...1
    let label: String
    let caption: LocalizedStringKey
    var color: Color = .green

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: max(0.02, min(1, value)))
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
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

enum Format {
    static func bytes(_ value: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(clamping: value))
    }

    static func hours(_ value: UInt64) -> String {
        if value >= 48 {
            return String(localized: "format.hours.days",
                          defaultValue: "\(value) giờ (≈\(value / 24) ngày)")
        }
        return String(localized: "format.hours", defaultValue: "\(value) giờ")
    }
}
