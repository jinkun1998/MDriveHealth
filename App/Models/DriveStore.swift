/*
 * DriveStore.swift — observable state: discovered drives + latest readings.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import Foundation
import Observation
import MDriveHealthCore

/// Everything the UI knows about one drive.
struct DriveSnapshot: Identifiable {
    let drive: DriveInfo
    var reading: DriveReading?
    var health: HealthReport?
    var lastError: String?
    var lastUpdated: Date?

    var id: UInt64 { drive.id }
}

@MainActor
@Observable
final class DriveStore {
    private(set) var snapshots: [DriveSnapshot] = []
    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?
    var showVirtualDrives = false

    /// Best-effort persistent history; nil when the database cannot be opened.
    let history: HistoryStore? = try? HistoryStore()

    /// Kernel-log I/O errors seen in the last 24h, keyed by BSD name.
    private(set) var ioErrorCounts: [String: Int] = [:]

    /// Snapshots the sidebar shows, honoring the virtual-drive filter.
    var visibleSnapshots: [DriveSnapshot] {
        showVirtualDrives ? snapshots : snapshots.filter { !$0.drive.isVirtual }
    }

    var internalDrives: [DriveSnapshot] { visibleSnapshots.filter { $0.drive.isInternal } }
    var externalDrives: [DriveSnapshot] { visibleSnapshots.filter { !$0.drive.isInternal } }

    /// The worst health rating across all probed drives (drives the app badge).
    var worstRating: HealthRating? {
        snapshots.compactMap { $0.health?.rating }.max()
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let historyStore = history
        let result = await Task.detached(priority: .userInitiated) {
            () -> [DriveSnapshot] in
            guard let drives = try? DriveEnumerator().enumerate() else { return [] }
            return drives.map { drive in
                var snapshot = DriveSnapshot(drive: drive)
                guard drive.smartInterface != .unsupported, !drive.isVirtual else {
                    return snapshot
                }
                do {
                    let reading = try DriveProber.read(drive: drive)
                    snapshot.reading = reading
                    snapshot.health = reading.evaluateHealth()
                    snapshot.lastUpdated = Date()
                    if let health = snapshot.health {
                        try? historyStore?.record(
                            driveKey: HistoryStore.driveKey(for: drive),
                            bsdName: drive.bsdName,
                            reading: reading, health: health)
                    }
                } catch {
                    snapshot.lastError = error.localizedDescription
                }
                return snapshot
            }
        }.value

        snapshots = result
        lastRefresh = Date()
        pruneHistoryOccasionally()
        refreshIOErrors(for: result.map(\.drive.bsdName))
    }

    /// Scans the unified log off the main thread; failures leave counts empty.
    private func refreshIOErrors(for bsdNames: [String]) {
        Task.detached(priority: .background) {
            let events = IOErrorWatcher.recentErrors(withinMinutes: 24 * 60)
            guard !events.isEmpty else { return }
            var counts: [String: Int] = [:]
            for name in bsdNames where !name.isEmpty {
                counts[name] = events.filter { $0.message.contains(name) }.count
            }
            let result = counts
            await MainActor.run { [weak self] in
                self?.ioErrorCounts = result
            }
        }
    }

    private var lastPrune: Date?

    private func pruneHistoryOccasionally() {
        // Keep 12 months of history; prune at most once per app day.
        if let lastPrune, Date().timeIntervalSince(lastPrune) < 86_400 { return }
        lastPrune = Date()
        try? history?.pruneOlderThan(Date().addingTimeInterval(-365 * 86_400))
    }
}
