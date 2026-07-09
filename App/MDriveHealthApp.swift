/*
 * MDriveHealthApp.swift — application entry point.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import SwiftUI

@main
struct MDriveHealthApp: App {
    @State private var store = DriveStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .frame(minWidth: 860, minHeight: 560)
                .task { await store.refresh() }
        }
        .windowToolbarStyle(.unified)
    }
}
