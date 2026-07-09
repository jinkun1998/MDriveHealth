/*
 * MonitoringController.swift — background polling + degradation alerts.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import Foundation
import Observation
import UserNotifications
import MDriveHealthCore

enum SettingsKeys {
    static let pollIntervalMinutes = "pollIntervalMinutes"   // Int, default 5
    static let alertTempThreshold = "alertTempThreshold"     // Int °C, default 60
    static let monitoringEnabled = "monitoringEnabled"       // Bool, default true
    static let showMenuBar = "showMenuBar"                   // Bool, default true
    static let backupReminderPrefix = "backupReminder."

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            pollIntervalMinutes: 5,
            alertTempThreshold: 60,
            monitoringEnabled: true,
            showMenuBar: true,
        ])
    }
}

@MainActor
@Observable
final class MonitoringController {
    private let store: DriveStore
    private var timer: Timer?
    /// Last state we alerted about, per drive key — avoids repeating alerts.
    private var alertedState: [String: AlertState] = [:]

    private struct AlertState {
        var rating: HealthRating
        var defects: UInt64
        var overTemp: Bool
    }

    init(store: DriveStore) {
        self.store = store
        SettingsKeys.registerDefaults()
    }

    func start() {
        requestNotificationPermission()
        scheduleTimer()
        // Refreshes happen via ContentView .task on launch; the timer handles
        // subsequent polls.
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let minutes = max(1, UserDefaults.standard.integer(forKey: SettingsKeys.pollIntervalMinutes))
        let timer = Timer(timeInterval: TimeInterval(minutes * 60), repeats: true) { _ in
            Task { @MainActor [weak self] in await self?.tick() }
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() async {
        guard UserDefaults.standard.bool(forKey: SettingsKeys.monitoringEnabled) else {
            scheduleTimer() // pick up interval changes even while paused
            return
        }
        await store.refresh()
        evaluateAlerts()
        scheduleTimer()
    }

    /// Compares the latest snapshots against previously alerted state and
    /// posts notifications for degradations.
    func evaluateAlerts() {
        let threshold = UserDefaults.standard.integer(forKey: SettingsKeys.alertTempThreshold)

        for snapshot in store.snapshots {
            guard let health = snapshot.health, let reading = snapshot.reading else { continue }
            let key = HistoryStore.driveKey(for: snapshot.drive)
            let defects = RiskAdvisor.dangerousCounter(reading: reading)
            let overTemp = (reading.temperatureCelsius ?? 0) >= threshold && threshold > 0
            let previous = alertedState[key]
            let persistedDefects = snapshot.previousHistory.map {
                ($0.defectCount ?? 0) &+ ($0.pendingSectors ?? 0)
            }

            let model = snapshot.drive.model
            if let previous {
                if health.rating > previous.rating, health.rating >= .warning {
                    notify(title: String(localized: "notify.degraded.title",
                                         defaultValue: "Sức khoẻ ổ đĩa giảm: \(model)"),
                           body: String(localized: "notify.degraded.body",
                                        defaultValue: "Tình trạng chuyển từ “\(previous.rating.displayName)” xuống “\(health.rating.displayName)” (\(health.score)/100). Hãy sao lưu dữ liệu và kiểm tra chi tiết trong MDriveHealth."))
                }
                if defects > previous.defects {
                    notify(title: String(localized: "notify.defects.title",
                                         defaultValue: "Phát hiện lỗi mới: \(model)"),
                           body: String(localized: "notify.defects.body",
                                        defaultValue: "Số sector lỗi/media error tăng từ \(Int(clamping: previous.defects)) lên \(Int(clamping: defects)). Đây là dấu hiệu bề mặt lưu trữ đang xuống cấp."))
                }
                if overTemp, !previous.overTemp {
                    notify(title: String(localized: "notify.temp.title",
                                         defaultValue: "Nhiệt độ cao: \(model)"),
                           body: String(localized: "notify.temp.body",
                                        defaultValue: "Ổ đĩa đạt \(reading.temperatureCelsius ?? 0)°C, vượt ngưỡng cảnh báo \(threshold)°C."))
                }
            } else if health.rating >= .failing {
                // First sighting of an already-failing drive still deserves an alert.
                notify(title: String(localized: "notify.failing.title",
                                     defaultValue: "Ổ đĩa đang hỏng: \(model)"),
                       body: String(localized: "notify.failing.body",
                                    defaultValue: "Tình trạng: \(health.rating.displayName) (\(health.score)/100). Sao lưu dữ liệu ngay lập tức!"))
            } else if let persistedDefects, defects > persistedDefects {
                notify(title: String(localized: "notify.defects.title",
                                     defaultValue: "Phát hiện lỗi mới: \(model)"),
                       body: String(localized: "notify.defects.body",
                                    defaultValue: "Số sector lỗi/media error tăng từ \(Int(clamping: persistedDefects)) lên \(Int(clamping: defects)). Đây là dấu hiệu bề mặt lưu trữ đang xuống cấp."))
            }

            maybeRemindBackup(key: key, model: model, health: health)
            alertedState[key] = AlertState(rating: health.rating, defects: defects,
                                           overTemp: overTemp)
        }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]) { _, _ in }
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func maybeRemindBackup(key: String, model: String, health: HealthReport) {
        guard health.rating >= .warning else { return }
        let defaultsKey = SettingsKeys.backupReminderPrefix + key
        let last = UserDefaults.standard.object(forKey: defaultsKey) as? Date
        if let last, Date().timeIntervalSince(last) < 86_400 { return }
        UserDefaults.standard.set(Date(), forKey: defaultsKey)
        notify(title: String(localized: "notify.backup.title",
                             defaultValue: "Backup reminder: \(model)"),
               body: String(localized: "notify.backup.body",
                            defaultValue: "The drive is at \(health.rating.displayName). Confirm your latest backup is usable before writing more important data."))
    }
}
