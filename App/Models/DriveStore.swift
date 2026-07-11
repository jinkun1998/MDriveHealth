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
    var previousHistory: HistoryPoint?
    var lastError: String?
    var lastUpdated: Date?
    /// The latest probe failed; `reading`/`health` are carried over from the
    /// last successful one.
    var isStale = false
    /// A background poll skipped this spun-down drive to let it sleep.
    var skippedWhileSleeping = false
    /// Mounted volumes on this drive (available even without SMART).
    var volumes: [VolumeUsage] = []

    var id: UInt64 { drive.id }
}

@MainActor
@Observable
final class DriveStore {
    private(set) var snapshots: [DriveSnapshot] = []
    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?
    private(set) var refreshError: String?
    var showVirtualDrives = false
    /// Set by notifications / the menu bar to select a drive in the main
    /// window; ContentView consumes and clears it.
    var pendingSelection: UInt64?
    /// A disk benchmark is running; background SMART polling pauses so its
    /// I/O does not skew the measurement.
    var benchmarkInProgress = false

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

    /// Re-enumerates and probes all drives. Background polls pass
    /// `wakingSleepingDrives: false` so spun-down HDDs keep sleeping; manual
    /// refreshes always read everything.
    func refresh(wakingSleepingDrives: Bool = true) async {
        guard !isRefreshing else { return }
        // A running benchmark owns the disk: EVERY refresh path (background
        // poll, manual button, self-test progress poll) must stay quiet so
        // SMART commands and log scans don't skew the measurement.
        guard !benchmarkInProgress else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let historyStore = history
        let result = await Task.detached(priority: .userInitiated) {
            () async -> (snapshots: [DriveSnapshot], error: String?) in
            let drives: [DriveInfo]
            do {
                drives = try DriveEnumerator().enumerate()
            } catch {
                return ([], error.localizedDescription)
            }
            // One mount-table read serves the whole fleet.
            let volumesByDrive = VolumeUsageReader.volumes(forDrives: drives)
            // Probe concurrently: one slow drive (e.g. an HDD spinning up)
            // must not stall the readings of every other drive.
            let snapshots = await withTaskGroup(of: (Int, DriveSnapshot).self) { group in
                for (index, drive) in drives.enumerated() {
                    group.addTask {
                        (index, Self.probe(drive: drive,
                                           volumes: volumesByDrive[drive.id] ?? [],
                                           historyStore: historyStore,
                                           wakingSleepingDrives: wakingSleepingDrives))
                    }
                }
                var ordered = [DriveSnapshot?](repeating: nil, count: drives.count)
                for await (index, snapshot) in group {
                    ordered[index] = snapshot
                }
                return ordered.compactMap { $0 }
            }
            return (snapshots, nil)
        }.value

        snapshots = merged(fresh: result.snapshots, previous: snapshots)
        refreshError = result.error
        lastRefresh = Date()
        pruneHistoryOccasionally()
        refreshIOErrors(for: result.snapshots.map(\.drive.bsdName))
    }

    /// Probes one drive; called concurrently off the main actor.
    nonisolated private static func probe(drive: DriveInfo,
                                          volumes: [VolumeUsage],
                                          historyStore: HistoryStore?,
                                          wakingSleepingDrives: Bool) -> DriveSnapshot {
        var snapshot = DriveSnapshot(drive: drive)
        // Capacity works for every drive — including USB enclosures that
        // cannot serve SMART.
        snapshot.volumes = volumes
        guard drive.smartInterface != .unsupported, !drive.isVirtual else {
            return snapshot
        }
        do {
            // The sleep policy lives in core DriveProber; background polls pass
            // avoidWakingIdle so a spun-down HDD is not woken to read SMART.
            switch try DriveProber.probe(drive: drive,
                                         avoidWakingIdle: !wakingSleepingDrives) {
            case .skippedAsleep:
                snapshot.skippedWhileSleeping = true
                return snapshot
            case .reading(let reading):
                let key = HistoryStore.driveKey(for: drive)
                snapshot.previousHistory = try? historyStore?.latest(driveKey: key)
                snapshot.reading = reading
                snapshot.health = reading.evaluateHealth()
                snapshot.lastUpdated = Date()
                if let health = snapshot.health {
                    try? historyStore?.record(
                        driveKey: key,
                        bsdName: drive.bsdName,
                        reading: reading, health: health)
                }
            }
        } catch {
            snapshot.lastError = error.localizedDescription
        }
        return snapshot
    }

    /// A transient probe failure (or a skipped sleeping drive) keeps the last
    /// good reading on screen instead of blanking the UI.
    private func merged(fresh: [DriveSnapshot],
                        previous: [DriveSnapshot]) -> [DriveSnapshot] {
        let previousByID = Dictionary(previous.map { ($0.id, $0) },
                                      uniquingKeysWith: { first, _ in first })
        return fresh.map { snapshot in
            guard snapshot.reading == nil,
                  snapshot.skippedWhileSleeping || snapshot.lastError != nil,
                  let old = previousByID[snapshot.id], old.reading != nil
            else { return snapshot }
            var carried = snapshot
            carried.reading = old.reading
            carried.health = old.health
            carried.previousHistory = old.previousHistory
            carried.lastUpdated = old.lastUpdated
            carried.isStale = !snapshot.skippedWhileSleeping
            return carried
        }
    }

    private var lastIOScan: Date?
    /// Rolling 24h window of kernel I/O error events, fed by incremental scans.
    /// The window/merge/count algorithm lives in core `IOErrorMonitor`; this
    /// only owns the cadence and the off-main scan.
    private var ioErrorEvents: [IOErrorEvent] = []

    /// Scans the unified log off the main thread; failures leave counts empty.
    /// The first scan covers 24h; later ones only cover the gap since the
    /// previous scan (`log show` over a full day is expensive).
    private func refreshIOErrors(for bsdNames: [String]) {
        let now = Date()
        guard let scanMinutes = IOErrorMonitor.scanMinutes(lastScan: lastIOScan, now: now)
        else { return }
        let previousScan = lastIOScan
        lastIOScan = now   // claim the slot so overlapping refreshes don't double-scan
        let knownEvents = ioErrorEvents
        Task.detached(priority: .background) {
            guard let fresh = IOErrorWatcher.recentErrors(withinMinutes: scanMinutes) else {
                // Scan failed — restore the marker so the missed window is
                // retried next time instead of silently dropped from the 24h
                // counts.
                await MainActor.run { [weak self] in self?.lastIOScan = previousScan }
                return
            }
            let window = IOErrorMonitor.merge(known: knownEvents, fresh: fresh, now: now)
            let counts = IOErrorMonitor.counts(events: window, bsdNames: bsdNames)
            await MainActor.run { [weak self] in
                self?.ioErrorEvents = window
                self?.ioErrorCounts = counts
            }
        }
    }

    private var lastPrune: Date?

    private func pruneHistoryOccasionally() {
        // Keep 12 months of history; prune at most once per app day. The
        // DELETE runs off-main — it can touch a year of rows.
        if let lastPrune, Date().timeIntervalSince(lastPrune) < 86_400 { return }
        lastPrune = Date()
        guard let history else { return }
        Task.detached(priority: .utility) {
            try? await history.pruneOlderThan(Date().addingTimeInterval(-365 * 86_400))
        }
    }
}
