/*
 * ContentView.swift — main split view: drive sidebar + detail.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import SwiftUI
import MDriveHealthCore

struct ContentView: View {
    @Environment(DriveStore.self) private var store
    @State private var selection: UInt64?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                if !store.internalDrives.isEmpty {
                    Section("Ổ trong") {
                        ForEach(store.internalDrives) { snapshot in
                            DriveRow(snapshot: snapshot).tag(snapshot.id)
                        }
                    }
                }
                if !store.externalDrives.isEmpty {
                    Section("Ổ ngoài / khác") {
                        ForEach(store.externalDrives) { snapshot in
                            DriveRow(snapshot: snapshot).tag(snapshot.id)
                        }
                    }
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
            if let id = selection,
               let snapshot = store.snapshots.first(where: { $0.id == id }) {
                DriveDetailView(snapshot: snapshot)
            } else {
                ContentUnavailableView(
                    "Chọn một ổ đĩa",
                    systemImage: "internaldrive",
                    description: Text("Chọn ổ đĩa ở thanh bên để xem tình trạng sức khoẻ.")
                )
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
                selection = store.internalDrives.first?.id ?? store.visibleSnapshots.first?.id
            }
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
                Image(systemName: health.rating.systemImage)
                    .foregroundStyle(health.rating.color)
                    .help("\(health.rating.displayName) — \(health.score)/100")
            } else if snapshot.drive.smartInterface == .unsupported {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.secondary)
                    .help("SMART không khả dụng qua \(snapshot.drive.interconnect)")
            }
        }
        .padding(.vertical, 2)
    }
}
