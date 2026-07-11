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
    @AppStorage(SettingsKeys.menuBarDisplay) private var menuBarDisplay = MenuBarDisplay.icon
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?
    @State private var checkingUpdates = false
    @State private var updateStatus: String?
    @State private var availableRelease: UpdateChecker.Release?
    @AppStorage("appLanguage") private var appLanguage = "system"
    @State private var languageNeedsRestart = false

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
                Toggle("Cảnh báo khi quá nhiệt", isOn: Binding(
                    get: { tempThreshold > 0 },
                    set: { tempThreshold = $0 ? 60 : 0 }
                ))
                .disabled(!monitoringEnabled)
                if tempThreshold > 0 {
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
            }

            Section("Hệ thống") {
                Toggle("Hiện biểu tượng trên thanh menu", isOn: $showMenuBar)
                if showMenuBar {
                    Picker("Hiển thị cạnh biểu tượng", selection: $menuBarDisplay) {
                        ForEach(MenuBarDisplay.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                }
                Toggle("Tự chạy khi đăng nhập", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enable in
                        updateLoginItem(enable: enable)
                    }
                if let loginItemError {
                    Text(loginItemError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Picker("Ngôn ngữ / Language", selection: $appLanguage) {
                    Text("Theo hệ thống / System").tag("system")
                    Text("Tiếng Việt").tag("vi")
                    Text("English").tag("en")
                }
                .onChange(of: appLanguage) { _, choice in
                    applyLanguage(choice)
                }
                if languageNeedsRestart {
                    HStack {
                        Text("Khởi động lại app để áp dụng ngôn ngữ mới.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Button("Khởi động lại ngay") { relaunchApp() }
                            .controlSize(.small)
                    }
                }
            }

            Section {
                LabeledContent("Phiên bản", value: UpdateChecker.currentVersion)
                LabeledContent("Drive database",
                               value: "smartmontools drivedb \(DriveDB.shared.version)")
                LabeledContent("Giấy phép", value: String(localized: "license.value",
                    defaultValue: "GPL-3.0-or-later — mã nguồn mở"))
                HStack {
                    Button("Kiểm tra bản cập nhật…") { checkUpdates() }
                        .disabled(checkingUpdates)
                    if checkingUpdates { ProgressView().controlSize(.small) }
                    if let release = availableRelease {
                        Button {
                            // Only https — the URL comes from remote JSON.
                            let url = release.downloadURL ?? release.url
                            if url.scheme == "https" { NSWorkspace.shared.open(url) }
                        } label: {
                            Label(String(localized: "update.download",
                                         defaultValue: "Tải bản \(release.version)"),
                                  systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    if let updateStatus {
                        Text(updateStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Về MDriveHealth")
            } footer: {
                // Markdown link renders clickable; "Maclife & Đồng Bọn" opens
                // the community Facebook group.
                Text("Made with ♥ for [Maclife & Đồng Bọn](https://www.facebook.com/groups/maclife.vn)")
                    .foregroundStyle(.secondary)
                    .tint(.accentColor)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize()
    }

    /// Standard per-app language override: set AppleLanguages and relaunch.
    private func applyLanguage(_ choice: String) {
        if choice == "system" {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([choice], forKey: "AppleLanguages")
        }
        languageNeedsRestart = true
    }

    private func relaunchApp() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL,
                                           configuration: configuration) { _, _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApp.terminate(nil)
        }
    }

    private func checkUpdates() {
        checkingUpdates = true
        updateStatus = nil
        Task {
            let result = await UpdateChecker.checkForUpdate()
            await MainActor.run {
                checkingUpdates = false
                switch result {
                case .available(let release):
                    availableRelease = release
                    updateStatus = String(localized: "update.available",
                                          defaultValue: "Có bản \(release.version) mới!")
                case .upToDate:
                    availableRelease = nil
                    updateStatus = String(localized: "update.latest",
                                          defaultValue: "Bạn đang dùng bản mới nhất.")
                case .failed(let message):
                    availableRelease = nil
                    updateStatus = String(localized: "update.failed",
                                          defaultValue: "Không kiểm tra được: \(message)")
                }
            }
        }
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
            loginItemError = String(localized: "login.error",
                defaultValue: "Không đổi được login item: \(error.localizedDescription)")
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
