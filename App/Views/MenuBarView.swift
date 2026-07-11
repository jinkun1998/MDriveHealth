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
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if store.visibleSnapshots.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(store.visibleSnapshots) { snapshot in
                            DriveMenuCard(snapshot: snapshot) {
                                // Select the tapped drive in the main window.
                                store.pendingSelection = snapshot.id
                                openMainWindow()
                            }
                        }
                    }
                    .padding(10)
                }
                .frame(maxHeight: 264)
            }

            Divider()
            footer
        }
        .frame(width: 300)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill((store.worstRating?.color ?? .accentColor).gradient)
                    .frame(width: 34, height: 34)
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "MDriveHealth")
                    .font(.headline)
                Text(summarySubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let worst = store.worstRating {
                HealthBadge(rating: worst)
                    .controlSize(.small)
            }
        }
        .padding(12)
    }

    private var emptyState: some View {
        HStack(spacing: 8) {
            Image(systemName: "internaldrive")
                .foregroundStyle(.secondary)
            Text(store.isRefreshing ? "Đang quét ổ đĩa…" : "Chưa phát hiện ổ đĩa")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    Task { await store.refresh() }
                } label: {
                    Label(store.isRefreshing ? "Đang đọc SMART…" : "Làm mới",
                          systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .disabled(store.isRefreshing)
                .keyboardShortcut("r")

                Button {
                    openMainWindow()
                } label: {
                    Label("Mở", systemImage: "macwindow")
                        .frame(maxWidth: .infinity)
                }
                .keyboardShortcut("o")
            }
            .buttonStyle(.borderedProminent)

            HStack(spacing: 8) {
                SettingsLink {
                    Label("Cài đặt…", systemImage: "gearshape")
                        .frame(maxWidth: .infinity)
                }
                .keyboardShortcut(",")

                Button {
                    NSApp.terminate(nil)
                } label: {
                    Label("Thoát", systemImage: "power")
                        .frame(maxWidth: .infinity)
                }
                .keyboardShortcut("q")
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.regular)
        .padding(12)
    }

    private var summarySubtitle: String {
        // "menubar.driveCount" carries plural variations (1 drive / n drives).
        let drives = String(localized: "menubar.driveCount",
                            defaultValue: "\(store.visibleSnapshots.count) ổ")
        let status: String
        if store.isRefreshing {
            status = String(localized: "menubar.readingShort", defaultValue: "đang đọc…")
        } else if let last = store.lastRefresh {
            status = String(localized: "menubar.checkedAt",
                            defaultValue: "kiểm tra \(last.formatted(date: .omitted, time: .shortened))")
        } else {
            status = String(localized: "menubar.notChecked", defaultValue: "chưa kiểm tra")
        }
        return "\(drives) · \(status)"
    }

    private func openMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// One drive row in the menu bar popover.
private struct DriveMenuCard: View {
    let snapshot: DriveSnapshot
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 9, height: 9)
                    .shadow(color: dotColor.opacity(0.5), radius: 2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.drive.model)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Text(snapshot.drive.bsdName)
                        if let temp = snapshot.reading?.temperatureCelsius {
                            Label("\(temp)°C", systemImage: "thermometer.medium")
                        }
                        if let life = snapshot.health?.lifetimeLeftPercent {
                            Label("\(life)%", systemImage: "bolt.heart")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)

                if let health = snapshot.health {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(health.rating.displayName)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(health.rating.color)
                        Text("\(health.score)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                } else {
                    Text(snapshot.drive.smartInterface == .unsupported ? "SMART n/a" : "…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .cardBackground(cornerRadius: 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var dotColor: Color {
        snapshot.health?.rating.color ?? .gray
    }
}
