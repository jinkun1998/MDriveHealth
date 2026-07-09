/*
 * SelfTestTab.swift — SMART self-test control (ATA drives).
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import SwiftUI
import MDriveHealthCore

struct SelfTestTab: View {
    let snapshot: DriveSnapshot
    @Environment(DriveStore.self) private var store
    @State private var startError: String?
    @State private var startedAt: Date?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch snapshot.drive.smartInterface {
                case .ata:
                    ataContent
                case .nvme:
                    infoBox(
                        title: "NVMe self-test không khả dụng trên macOS",
                        message: "Giao diện NVMe của macOS không cho phép ứng dụng gửi lệnh Device Self-test — hạn chế của hệ điều hành, áp dụng với mọi công cụ. Các chỉ số SMART ở tab Tổng quan vẫn phản ánh đầy đủ tình trạng ổ.")
                case .unsupported:
                    infoBox(title: "Không khả dụng",
                            message: "Ổ này không có kênh SMART nên không chạy được self-test.")
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var ataContent: some View {
        if case .ata(let reading) = snapshot.reading, let selfTest = reading.selfTest,
           selfTest.inProgress {
            VStack(alignment: .leading, spacing: 8) {
                Label("Self-test đang chạy", systemImage: "gearshape.2")
                    .font(.headline)
                ProgressView(value: Double(100 - (selfTest.percentRemaining ?? 0)),
                             total: 100)
                Text("Còn khoảng \(selfTest.percentRemaining ?? 0)%. " +
                     "Bấm Làm mới để cập nhật tiến độ.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }

        VStack(alignment: .leading, spacing: 10) {
            Text("Chạy self-test").font(.headline)
            Text("Self-test do chính firmware ổ đĩa thực hiện, an toàn với dữ liệu và có thể dùng ổ bình thường trong lúc chạy (tốc độ có thể giảm nhẹ).")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button {
                    start(extended: false)
                } label: {
                    Label("Test ngắn (~2 phút)", systemImage: "bolt")
                }
                Button {
                    start(extended: true)
                } label: {
                    Label("Test mở rộng (hàng giờ)", systemImage: "clock")
                }
            }
            if let startedAt {
                Text("Đã gửi lệnh lúc \(startedAt.formatted(date: .omitted, time: .standard)). " +
                     "Theo dõi tiến độ bằng nút Làm mới.")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            if let startError {
                Text(startError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func infoBox(title: LocalizedStringKey, message: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: "info.circle").font(.headline)
            Text(message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func start(extended: Bool) {
        do {
            try ATASMARTProvider(drive: snapshot.drive).startSelfTest(extended: extended)
            startedAt = Date()
            startError = nil
        } catch {
            startError = "Không chạy được self-test: \(error.localizedDescription)"
        }
    }
}
