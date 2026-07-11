/*
 * MDriveHealthApp.swift — application entry point.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import SwiftUI
import AppKit
import UserNotifications
import MDriveHealthCore

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    // The menu bar extra keeps monitoring alive after the window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Alerts stay visible even while the app is frontmost.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Tapping a drive alert routes through the app's URL scheme, which
    /// reopens the main window if needed and selects the drive
    /// (ContentView.onOpenURL).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        guard let idString = userInfo["driveRegistryEntryID"] as? String,
              let url = URL(string: "mdrivehealth://drive/\(idString)") else { return }
        await MainActor.run {
            NSWorkspace.shared.open(url)
        }
    }
}

/// What to show beside the menu bar icon. Raw values persist via @AppStorage;
/// the exhaustive switch means a new case can't silently fall through to icon.
enum MenuBarDisplay: String, CaseIterable, Identifiable {
    case icon, temp, score

    var id: String { rawValue }
    var label: LocalizedStringKey {
        switch self {
        case .icon: return "Không có gì"
        case .temp: return "Nhiệt độ ổ nóng nhất"
        case .score: return "Điểm sức khoẻ thấp nhất"
        }
    }
}

@main
struct MDriveHealthApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store: DriveStore
    @State private var monitor: MonitoringController
    @State private var benchmark: BenchmarkRunner
    @State private var capacityVerify: CapacityVerifyRunner
    @AppStorage(SettingsKeys.showMenuBar) private var showMenuBar = true
    @AppStorage(SettingsKeys.menuBarDisplay) private var menuBarDisplay = MenuBarDisplay.icon

    init() {
        SettingsKeys.registerDefaults()
        let store = DriveStore()
        _store = State(initialValue: store)
        _monitor = State(initialValue: MonitoringController(store: store))
        _benchmark = State(initialValue: BenchmarkRunner(store: store))
        _capacityVerify = State(initialValue: CapacityVerifyRunner(store: store))
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environment(store)
                .environment(benchmark)
                .environment(capacityVerify)
                .frame(minWidth: 860, minHeight: 560)
                .task {
                    monitor.start()
                    await store.refresh()
                    monitor.evaluateAlerts()
                }
        }
        .windowToolbarStyle(.unified)

        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarView()
                .environment(store)
        } label: {
            menuBarLabel
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }

    private var menuBarLabel: some View {
        HStack(spacing: 2) {
            Image(systemName: menuBarSymbol)
            if let value = menuBarValue {
                Text(verbatim: value)
            }
        }
    }

    /// Optional text next to the menu bar icon, per the display setting.
    private var menuBarValue: String? {
        switch menuBarDisplay {
        case .icon:
            return nil
        case .temp:
            return store.visibleSnapshots
                .compactMap { $0.reading?.temperatureCelsius }.max()
                .map { "\($0)°" }
        case .score:
            return store.visibleSnapshots
                .compactMap { $0.health?.score }.min()
                .map { "\($0)" }
        }
    }

    private var menuBarSymbol: String {
        switch store.worstRating {
        case .some(.failing), .some(.failed):
            return "externaldrive.fill.badge.xmark"
        case .some(.warning):
            return "externaldrive.fill.badge.exclamationmark"
        default:
            return "internaldrive"
        }
    }
}
