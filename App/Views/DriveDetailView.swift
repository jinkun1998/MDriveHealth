/*
 * DriveDetailView.swift — per-drive header + tabbed detail.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MDriveHealthCore

struct DriveDetailView: View {
    let snapshot: DriveSnapshot
    @Environment(DriveStore.self) private var store
    @State private var reportCopied = false

    private enum Tab: String, CaseIterable, Identifiable {
        case overview = "Tổng quan"
        case attributes = "Thuộc tính SMART"
        case history = "Lịch sử"
        case selfTest = "Self-test"
        case info = "Thiết bị"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .overview

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.vertical, 8)

            Group {
                switch tab {
                case .overview:
                    OverviewTab(snapshot: snapshot)
                case .attributes:
                    AttributesTab(snapshot: snapshot)
                case .history:
                    HistoryTab(snapshot: snapshot)
                case .selfTest:
                    SelfTestTab(snapshot: snapshot)
                case .info:
                    DeviceInfoTab(snapshot: snapshot)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(snapshot.drive.model)
        .toolbar {
            ToolbarItem {
                Menu {
                    Button {
                        copyReport()
                    } label: {
                        Label("Sao chép báo cáo", systemImage: "doc.on.doc")
                    }
                    Button {
                        saveReport()
                    } label: {
                        Label("Lưu báo cáo ra file…", systemImage: "square.and.arrow.down")
                    }
                } label: {
                    Label(reportCopied ? "Đã sao chép!" : "Báo cáo",
                          systemImage: reportCopied ? "checkmark" : "square.and.arrow.up")
                }
                .help("Xuất báo cáo text để đăng lên group hoặc gửi khi cần trợ giúp")
            }
        }
    }

    private var reportText: String {
        ReportGenerator.text(for: snapshot,
                             ioErrors24h: store.ioErrorCounts[snapshot.drive.bsdName])
    }

    private func copyReport() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(reportText, forType: .string)
        reportCopied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            reportCopied = false
        }
    }

    private func saveReport() {
        let panel = NSSavePanel()
        let model = snapshot.drive.model.replacingOccurrences(of: " ", with: "-")
        panel.nameFieldStringValue = "MDriveHealth-\(model).txt"
        panel.allowedContentTypes = [.plainText]
        let report = reportText
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? report.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: snapshot.drive.isInternal ? "internaldrive.fill" : "externaldrive.fill")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(snapshot.drive.model).font(.title3.weight(.semibold))
                HStack(spacing: 8) {
                    Text(Format.bytes(snapshot.drive.sizeBytes))
                    Text("·")
                    Text(snapshot.drive.interconnect)
                    Text("·")
                    Text(snapshot.drive.isSolidState ? "SSD" : "HDD")
                    if let serial = snapshot.drive.serialNumber {
                        Text("·")
                        Text("S/N \(serial)").textSelection(.enabled)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if let health = snapshot.health {
                HealthBadge(rating: health.rating)
            }
        }
        .padding()
    }
}
