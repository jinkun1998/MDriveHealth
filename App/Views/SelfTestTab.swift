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
    @State private var logEntries: [ATASelfTestLogEntry]?

    private var isTestRunning: Bool {
        snapshot.reading?.selfTestInProgress == true
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch snapshot.drive.smartInterface {
                case .ata:
                    ataContent
                    historySection
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
        // While a test runs and this tab is visible, poll for progress so the
        // user does not have to press Refresh. The drive under test is awake
        // by definition; don't wake unrelated sleeping drives every 30s.
        .task(id: "\(snapshot.id)-\(isTestRunning)") {
            guard isTestRunning else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                await store.refresh(wakingSleepingDrives: false)
            }
        }
        .task(id: "\(snapshot.id)-\(snapshot.lastUpdated?.timeIntervalSince1970 ?? 0)") {
            await loadSelfTestLog()
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
                Text(String(localized: "selftest.progress",
                            defaultValue: "Còn khoảng \(selfTest.percentRemaining ?? 0)%. Tiến độ tự cập nhật mỗi 30 giây."))
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
                Text(String(localized: "selftest.started",
                            defaultValue: "Đã gửi lệnh lúc \(startedAt.formatted(date: .omitted, time: .standard)). Tiến độ sẽ tự cập nhật khi tab này đang mở."))
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

    @ViewBuilder
    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Lịch sử self-test")
                .font(.headline)
            if let entries = logEntries, !entries.isEmpty {
                VStack(spacing: 0) {
                    ForEach(entries) { entry in
                        SelfTestLogRow(entry: entry)
                        if entry.id != entries.last?.id { Divider() }
                    }
                }
                .background(.quaternary.opacity(0.35),
                            in: RoundedRectangle(cornerRadius: 8))
            } else if logEntries != nil {
                Text("Chưa có self-test nào được ghi nhận trên ổ này.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("Ổ này không cho đọc nhật ký self-test (thường do cầu nối/bridge chặn lệnh READ LOG).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func loadSelfTestLog() async {
        guard snapshot.drive.smartInterface == .ata else { return }
        let drive = snapshot.drive
        logEntries = await Task.detached(priority: .utility) {
            try? ATASMARTProvider(drive: drive).readSelfTestLog()
        }.value
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
            // Pick up the "in progress" state right away so progress polling
            // kicks in without a manual refresh.
            Task { await store.refresh() }
        } catch {
            startError = String(localized: "selftest.error",
                                defaultValue: "Không chạy được self-test: \(error.localizedDescription)")
        }
    }
}

/// One row of the self-test history list.
private struct SelfTestLogRow: View {
    let entry: ATASelfTestLogEntry

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.isExtended ? "Test mở rộng" : "Test ngắn")
                    .font(.callout.weight(.medium))
                Text(String(localized: "selftest.log.hours",
                            defaultValue: "Lúc ổ chạy được \(Int(clamping: entry.powerOnHours)) giờ"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(resultText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
                if let lba = entry.failingLBA {
                    Text(verbatim: "LBA \(lba)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var symbol: String {
        if entry.inProgress { return "gearshape.2" }
        if entry.passed { return "checkmark.circle.fill" }
        if entry.wasAborted { return "minus.circle" }
        return "xmark.octagon.fill"
    }

    private var color: Color {
        if entry.inProgress { return .blue }
        if entry.passed { return .green }
        if entry.wasAborted { return .secondary }
        return .red
    }

    private var resultText: String {
        if entry.inProgress {
            return String(localized: "selftest.log.running",
                          defaultValue: "Đang chạy (\(entry.percentRemaining)% còn lại)")
        }
        if entry.passed {
            return String(localized: "selftest.log.passed", defaultValue: "Đạt")
        }
        if entry.wasAborted {
            return String(localized: "selftest.log.aborted", defaultValue: "Đã huỷ")
        }
        return String(localized: "selftest.log.failed", defaultValue: "LỖI")
    }
}
