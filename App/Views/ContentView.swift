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
    // Loaded in .task — an initializer default would re-run the IOKit read on
    // every struct re-init and discard the result (@State keeps the first).
    @State private var battery: BatteryInfo?

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
                    if battery != nil {
                        Label("Pin", systemImage: batterySymbol)
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
                .disabled(store.isRefreshing || store.benchmarkInProgress)
                .help(store.benchmarkInProgress
                      ? "Đang đo tốc độ — tạm dừng đọc SMART để không nhiễu kết quả"
                      : "Đọc lại SMART từ tất cả ổ đĩa")
            }
        }
        // Both selection triggers below funnel through pendingSelection so
        // there is one validated path: initial:true consumes a value the menu
        // bar set before this view existed; the snapshots.count change retries
        // a pending id that has now loaded and otherwise picks the default.
        .onChange(of: store.snapshots.count) { applyPendingSelectionOrDefault() }
        .onChange(of: store.pendingSelection, initial: true) { applyPendingSelectionOrDefault() }
        .task { battery = BatteryReader.read() }
        .onChange(of: store.lastRefresh) {
            battery = BatteryReader.read()
        }
        // mdrivehealth://drive/<registryEntryID> — notification taps; macOS
        // opens the window for the URL when it was closed. Feed the same
        // pendingSelection channel rather than selecting directly.
        .onOpenURL { url in
            guard url.scheme == "mdrivehealth", url.host() == "drive",
                  let id = UInt64(url.lastPathComponent) else { return }
            store.pendingSelection = id
            NSApp.activate(ignoringOtherApps: true)
            applyPendingSelectionOrDefault()
        }
    }

    /// Applies a requested drive selection once that drive is actually present
    /// (a replug reassigns registryEntryIDs, so an unknown id is held, not
    /// turned into a phantom row), else falls back to the default selection.
    private func applyPendingSelectionOrDefault() {
        if let id = store.pendingSelection {
            if store.snapshots.contains(where: { $0.id == id }) {
                selection = .drive(id)
                store.pendingSelection = nil
            }
            return
        }
        if selection == nil {
            selection = store.visibleSnapshots.isEmpty ? .memory : .allDrives
        }
    }

    /// Sidebar battery icon mirrors the real charge level.
    private var batterySymbol: String {
        guard let battery else { return "battery.100" }
        if battery.isCharging { return "battery.100.bolt" }
        switch battery.chargePercent {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
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
                  ? "internaldrive.fill" : "externaldrive.fill")
                .foregroundStyle(snapshot.health?.rating.color ?? .secondary)
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
