/*
 * DriveDetailView.swift — per-drive header + tabbed detail.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import SwiftUI
import MDriveHealthCore

struct DriveDetailView: View {
    let snapshot: DriveSnapshot

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
