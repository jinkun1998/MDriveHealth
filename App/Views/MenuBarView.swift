/*
 * MenuBarView.swift — menu bar quick status.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import SwiftUI
import AppKit
import MDriveHealthCore

struct MenuBarView: View {
    @Environment(DriveStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            ForEach(store.visibleSnapshots) { snapshot in
                let health = snapshot.health
                let temp = snapshot.reading?.temperatureCelsius
                Button {
                    openMainWindow()
                } label: {
                    HStack {
                        Image(systemName: health?.rating.systemImage ?? "questionmark.circle")
                        Text(menuLine(snapshot: snapshot, health: health, temp: temp))
                    }
                }
            }

            Divider()

            Button("Mở MDriveHealth") { openMainWindow() }
                .keyboardShortcut("o")
            Button(store.isRefreshing ? "Đang đọc SMART…" : "Làm mới ngay") {
                Task { await store.refresh() }
            }
            .disabled(store.isRefreshing)
            .keyboardShortcut("r")

            Divider()

            SettingsLink { Text("Cài đặt…") }
                .keyboardShortcut(",")
            Button("Thoát MDriveHealth") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }

    private func menuLine(snapshot: DriveSnapshot, health: HealthReport?,
                          temp: Int?) -> String {
        var parts = [snapshot.drive.bsdName.isEmpty
                     ? snapshot.drive.model : snapshot.drive.bsdName]
        if let temp { parts.append("\(temp)°C") }
        if let health { parts.append("\(health.rating.displayName) \(health.score)") }
        else { parts.append("SMART n/a") }
        return parts.joined(separator: " · ")
    }

    private func openMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
