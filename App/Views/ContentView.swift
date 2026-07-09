/*
 * ContentView.swift — main split view: drive/system sidebar + detail.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import SwiftUI
import MDriveHealthCore

enum SidebarItem: Hashable {
    case allDrives
    case drive(UInt64)
    case battery
    case sensors
    case memory
}

struct ContentView: View {
    @Environment(DriveStore.self) private var store
    @State private var selection: SidebarItem?
    @State private var hasBattery = BatteryReader.read() != nil

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    Label("Tất cả ổ đĩa", systemImage: "list.bullet.rectangle")
                        .tag(SidebarItem.allDrives)
                }
                if !store.internalDrives.isEmpty {
                    Section("Ổ trong") {
                        ForEach(store.internalDrives) { snapshot in
                            DriveRow(snapshot: snapshot)
                                .tag(SidebarItem.drive(snapshot.id))
                        }
                    }
                }
                if !store.externalDrives.isEmpty {
                    Section("Ổ ngoài / khác") {
                        ForEach(store.externalDrives) { snapshot in
                            DriveRow(snapshot: snapshot)
                                .tag(SidebarItem.drive(snapshot.id))
                        }
                    }
                }
                Section("Hệ thống") {
                    if hasBattery {
                        Label("Pin", systemImage: "battery.75")
                            .tag(SidebarItem.battery)
                    }
                    Label("Cảm biến nhiệt", systemImage: "thermometer.medium")
                        .tag(SidebarItem.sensors)
                    Label("Bộ nhớ (RAM)", systemImage: "memorychip")
                        .tag(SidebarItem.memory)
                }
            }
            .navigationSplitViewColumnWidth(min: 230, ideal: 260)
            .navigationTitle("MDriveHealth")
            .overlay {
                if store.snapshots.isEmpty && store.isRefreshing {
                    ProgressView("Đang quét ổ đĩa…")
                }
            }
        } detail: {
            switch selection {
            case .allDrives:
                DriveCompareView()
            case .drive(let id):
                if let snapshot = store.snapshots.first(where: { $0.id == id }) {
                    DriveDetailView(snapshot: snapshot)
                } else {
                    noSelection
                }
            case .battery:
                BatteryView()
            case .sensors:
                SensorsView()
            case .memory:
                MemoryView()
            case nil:
                noSelection
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await store.refresh() }
                } label: {
                    if store.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Làm mới", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(store.isRefreshing)
                .help("Đọc lại SMART từ tất cả ổ đĩa")
            }
        }
        .onChange(of: store.snapshots.count) {
            if selection == nil {
                selection = store.visibleSnapshots.isEmpty ? .memory : .allDrives
            }
        }
    }

    private var noSelection: some View {
        if let error = store.refreshError {
            ContentUnavailableView(
                "Không quét được ổ đĩa",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
        } else {
            ContentUnavailableView(
                "Chọn một mục",
                systemImage: "internaldrive",
                description: Text("Chọn ổ đĩa hoặc mục hệ thống ở thanh bên.")
            )
        }
    }
}

private struct DriveRow: View {
    let snapshot: DriveSnapshot

    var body: some View {
        HStack {
            Image(systemName: snapshot.drive.isInternal
                  ? "internaldrive" : "externaldrive")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.drive.model)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(snapshot.drive.bsdName)
                    Text(Format.bytes(snapshot.drive.sizeBytes))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if let health = snapshot.health {
                Text(health.rating.displayName)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(health.rating.color, in: Capsule())
                    .help("\(health.rating.displayName) — \(health.score)/100")
            } else if snapshot.drive.smartInterface == .unsupported {
                Text("n/a")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    .help("SMART không khả dụng qua \(snapshot.drive.interconnect)")
            }
        }
        .padding(.vertical, 2)
    }
}
