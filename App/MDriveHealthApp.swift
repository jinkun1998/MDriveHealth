/*
 * MDriveHealthApp.swift — application entry point.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import SwiftUI
import AppKit
import MDriveHealthCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    // The menu bar extra keeps monitoring alive after the window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct MDriveHealthApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store: DriveStore
    @State private var monitor: MonitoringController
    @AppStorage(SettingsKeys.showMenuBar) private var showMenuBar = true

    init() {
        SettingsKeys.registerDefaults()
        let store = DriveStore()
        _store = State(initialValue: store)
        _monitor = State(initialValue: MonitoringController(store: store))
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environment(store)
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
            Image(systemName: menuBarSymbol)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
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
