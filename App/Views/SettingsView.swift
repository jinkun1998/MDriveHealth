/*
 * SettingsView.swift — app preferences.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import SwiftUI
import ServiceManagement
import MDriveHealthCore

struct SettingsView: View {
    @AppStorage(SettingsKeys.pollIntervalMinutes) private var pollInterval = 5
    @AppStorage(SettingsKeys.alertTempThreshold) private var tempThreshold = 60
    @AppStorage(SettingsKeys.monitoringEnabled) private var monitoringEnabled = true
    @AppStorage(SettingsKeys.showMenuBar) private var showMenuBar = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section("Theo dõi nền") {
                Toggle("Bật theo dõi & cảnh báo tự động", isOn: $monitoringEnabled)
                Picker("Chu kỳ đọc SMART", selection: $pollInterval) {
                    Text("1 phút").tag(1)
                    Text("5 phút").tag(5)
                    Text("10 phút").tag(10)
                    Text("30 phút").tag(30)
                    Text("60 phút").tag(60)
                }
                .disabled(!monitoringEnabled)
                LabeledContent("Ngưỡng cảnh báo nhiệt độ") {
                    HStack {
                        Slider(value: Binding(
                            get: { Double(tempThreshold) },
                            set: { tempThreshold = Int($0) }
                        ), in: 45...85, step: 5)
                        Text("\(tempThreshold)°C").monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                .disabled(!monitoringEnabled)
            }

            Section("Hệ thống") {
                Toggle("Hiện biểu tượng trên thanh menu", isOn: $showMenuBar)
                Toggle("Tự chạy khi đăng nhập", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enable in
                        updateLoginItem(enable: enable)
                    }
                if let loginItemError {
                    Text(loginItemError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section {
                LabeledContent("Drive database",
                               value: "smartmontools drivedb \(DriveDB.shared.version)")
                LabeledContent("Giấy phép", value: "GPL-3.0-or-later — mã nguồn mở")
            } header: {
                Text("Về MDriveHealth")
            } footer: {
                Text("Miễn phí cho cộng đồng Maclife 🇻🇳")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize()
    }

    private func updateLoginItem(enable: Bool) {
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = "Không đổi được login item: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
