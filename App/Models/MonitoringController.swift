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
    static let alertTempThreshold = "alertTempThreshold"     // Int °C, default 60; 0 = off
    static let monitoringEnabled = "monitoringEnabled"       // Bool, default true
    static let showMenuBar = "showMenuBar"                   // Bool, default true
    static let menuBarDisplay = "menuBarDisplay"             // "icon" | "temp" | "score"
    static let backupReminderPrefix = "backupReminder."
    // Persisted per-drive self-test tracking so completion alerts survive an
    // app restart and don't depend on a poll landing mid-test.
    static let selfTestCodePrefix = "selfTestCode."          // Int: last terminal statusCode
    static let selfTestRunningPrefix = "selfTestRunning."    // Bool: a run was observed

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            pollIntervalMinutes: 5,
            alertTempThreshold: 60,
            monitoringEnabled: true,
            showMenuBar: true,
            menuBarDisplay: "icon",
        ])
    }
}

@MainActor
@Observable
final class MonitoringController {
    private let store: DriveStore
    private var timer: Timer?
    private var scheduledIntervalMinutes = 0
    private var defaultsObserver: (any NSObjectProtocol)?
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
        // Settings has no reference to this controller, so interval changes
        // arrive via UserDefaults — reschedule immediately instead of waiting
        // out the previously scheduled (possibly much longer) interval.
        // The controller lives for the app's lifetime; the observer is never
        // removed.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.rescheduleIfIntervalChanged() }
        }
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
        scheduledIntervalMinutes = minutes
    }

    private func rescheduleIfIntervalChanged() {
        guard timer != nil else { return } // not started yet
        let minutes = max(1, UserDefaults.standard.integer(forKey: SettingsKeys.pollIntervalMinutes))
        if minutes != scheduledIntervalMinutes {
            scheduleTimer()
        }
    }

    private func tick() async {
        guard UserDefaults.standard.bool(forKey: SettingsKeys.monitoringEnabled) else {
            return
        }
        // Background polls let spun-down drives sleep.
        await store.refresh(wakingSleepingDrives: false)
        evaluateAlerts()
    }

    /// Compares the latest snapshots against previously alerted state and
    /// posts notifications for degradations.
    func evaluateAlerts() {
        let threshold = UserDefaults.standard.integer(forKey: SettingsKeys.alertTempThreshold)

        for snapshot in store.snapshots {
            guard let health = snapshot.health, let reading = snapshot.reading else { continue }
            let key = HistoryStore.driveKey(for: snapshot.drive)
            let defects = reading.dangerousDefectTotal
            let overTemp = (reading.temperatureCelsius ?? 0) >= threshold && threshold > 0
            let previous = alertedState[key]
            let persistedDefects = snapshot.previousHistory.map {
                ($0.defectCount ?? 0) &+ ($0.pendingSectors ?? 0)
            }

            let model = snapshot.drive.model
            let driveID = snapshot.drive.id
            evaluateSelfTest(reading: reading, key: key, model: model, driveID: driveID)
            if let previous {
                if health.rating > previous.rating, health.rating >= .warning {
                    notify(title: String(localized: "notify.degraded.title",
                                         defaultValue: "Sức khoẻ ổ đĩa giảm: \(model)"),
                           body: String(localized: "notify.degraded.body",
                                        defaultValue: "Tình trạng chuyển từ “\(previous.rating.displayName)” xuống “\(health.rating.displayName)” (\(health.score)/100). Hãy sao lưu dữ liệu và kiểm tra chi tiết trong MDriveHealth."),
                           driveID: driveID)
                }
                if defects > previous.defects {
                    notify(title: String(localized: "notify.defects.title",
                                         defaultValue: "Phát hiện lỗi mới: \(model)"),
                           body: String(localized: "notify.defects.body",
                                        defaultValue: "Số sector lỗi/media error tăng từ \(Int(clamping: previous.defects)) lên \(Int(clamping: defects)). Đây là dấu hiệu bề mặt lưu trữ đang xuống cấp."),
                           driveID: driveID)
                }
                if overTemp, !previous.overTemp {
                    notify(title: String(localized: "notify.temp.title",
                                         defaultValue: "Nhiệt độ cao: \(model)"),
                           body: String(localized: "notify.temp.body",
                                        defaultValue: "Ổ đĩa đạt \(reading.temperatureCelsius ?? 0)°C, vượt ngưỡng cảnh báo \(threshold)°C."),
                           driveID: driveID)
                }
            } else if health.rating >= .failing {
                // First sighting of an already-failing drive still deserves an alert.
                notify(title: String(localized: "notify.failing.title",
                                     defaultValue: "Ổ đĩa đang hỏng: \(model)"),
                       body: String(localized: "notify.failing.body",
                                    defaultValue: "Tình trạng: \(health.rating.displayName) (\(health.score)/100). Sao lưu dữ liệu ngay lập tức!"),
                       driveID: driveID)
            } else if let persistedDefects, defects > persistedDefects {
                notify(title: String(localized: "notify.defects.title",
                                     defaultValue: "Phát hiện lỗi mới: \(model)"),
                       body: String(localized: "notify.defects.body",
                                    defaultValue: "Số sector lỗi/media error tăng từ \(Int(clamping: persistedDefects)) lên \(Int(clamping: defects)). Đây là dấu hiệu bề mặt lưu trữ đang xuống cấp."),
                       driveID: driveID)
            }

            maybeRemindBackup(key: key, model: model, health: health,
                              driveID: driveID)
            alertedState[key] = AlertState(rating: health.rating, defects: defects,
                                           overTemp: overTemp)
        }
    }

    /// Notifies when an ATA self-test finishes. Detection is restart-safe: the
    /// last terminal statusCode and a "run was seen" flag are persisted per
    /// drive, so a test that completes between polls (or while the app was
    /// closed) is still reported once — without catching it mid-run and
    /// without any extra hardware I/O (byte 363 rides along every SMART read).
    private func evaluateSelfTest(reading: DriveReading, key: String,
                                  model: String, driveID: UInt64) {
        guard let status = reading.ataSelfTest else { return }
        let defaults = UserDefaults.standard
        let codeKey = SettingsKeys.selfTestCodePrefix + key
        let runningKey = SettingsKeys.selfTestRunningPrefix + key

        if status.inProgress {
            defaults.set(true, forKey: runningKey)
            return
        }

        let code = Int(status.statusCode)
        let sawRun = defaults.bool(forKey: runningKey)
        // -1 = never observed before → this reading is the baseline, not news.
        let previousCode = defaults.object(forKey: codeKey) as? Int ?? -1
        let resultChanged = previousCode >= 0 && code != previousCode

        defer {
            defaults.set(code, forKey: codeKey)
            defaults.set(false, forKey: runningKey)
        }
        // Report a genuinely new terminal result; a user abort is not a fault.
        guard sawRun || resultChanged, !status.wasAborted else { return }
        notify(title: String(localized: "notify.selftest.title",
                             defaultValue: "Self-test hoàn tất: \(model)"),
               body: status.passed
                   ? String(localized: "notify.selftest.passed",
                            defaultValue: "Kết quả: ĐẠT — không phát hiện lỗi khi ổ tự kiểm tra.")
                   : String(localized: "notify.selftest.failed",
                            defaultValue: "Kết quả: CÓ VẤN ĐỀ — mở tab Self-test để xem chi tiết và sao lưu dữ liệu sớm."),
               driveID: driveID)
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]) { _, _ in }
    }

    /// `driveID` rides along in userInfo so tapping the notification can
    /// select the drive in the main window (see AppDelegate).
    private func notify(title: String, body: String, driveID: UInt64? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let driveID {
            content.userInfo = ["driveRegistryEntryID": String(driveID)]
        }
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func maybeRemindBackup(key: String, model: String,
                                   health: HealthReport, driveID: UInt64?) {
        guard health.rating >= .warning else { return }
        let defaultsKey = SettingsKeys.backupReminderPrefix + key
        let last = UserDefaults.standard.object(forKey: defaultsKey) as? Date
        if let last, Date().timeIntervalSince(last) < 86_400 { return }
        UserDefaults.standard.set(Date(), forKey: defaultsKey)
        notify(title: String(localized: "notify.backup.title",
                             defaultValue: "Backup reminder: \(model)"),
               body: String(localized: "notify.backup.body",
                            defaultValue: "The drive is at \(health.rating.displayName). Confirm your latest backup is usable before writing more important data."),
               driveID: driveID)
    }
}
