/*
 * BenchmarkRunner.swift — drives DiskBenchmarkEngine from the UI: one run at a
 * time, live progress/samples, persistence, and background-poll suppression.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import Foundation
import Observation
import MDriveHealthCore

@MainActor
@Observable
final class BenchmarkRunner {
    enum State {
        case idle
        case running(BenchmarkPhase)
        case finished(BenchmarkResult)
        case failed(String)              // localized message
    }

    /// One point on the live throughput chart.
    struct SpeedSample: Identifiable {
        let id: Int
        let phase: BenchmarkPhase
        let elapsed: TimeInterval        // seconds since the run started
        let megabytesPerSecond: Double
    }

    private(set) var state: State = .idle
    private(set) var progress: BenchmarkProgress?
    private(set) var samples: [SpeedSample] = []
    // Maintained incrementally per progress tick so the live gauges never
    // have to scan the samples array during a render pass.
    private(set) var lastWriteMBps: Double = 0
    private(set) var lastReadMBps: Double = 0
    private(set) var peakMBps: Double = 0
    private(set) var runningDriveID: UInt64?
    private(set) var runningVolume: VolumeUsage?
    /// Drive the current/most recent run belongs to. Unlike runningDriveID it
    /// SURVIVES finish(), so finished/failed states stay scoped to their
    /// drive's tab instead of leaking onto every drive (cleared by reset()).
    private(set) var ownerDriveID: UInt64?

    private let store: DriveStore
    private let engine = DiskBenchmarkEngine()
    private var task: Task<Void, Never>?
    private var cancelFlag: CancelBox?
    private var sampleCounter = 0
    /// Bumped on every start(); progress hops carry their generation so a
    /// straggler Task from a cancelled run can't inject samples into the next.
    private var runGeneration = 0

    init(store: DriveStore) { self.store = store }

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    /// True when a run is active on a drive other than the given one.
    func isBusyElsewhere(driveID: UInt64) -> Bool {
        isRunning && runningDriveID != nil && runningDriveID != driveID
    }

    func start(snapshot: DriveSnapshot, volume: VolumeUsage, config: BenchmarkConfig) {
        guard !isRunning else { return }
        let driveKey = HistoryStore.driveKey(for: snapshot.drive)
        let history = store.history
        let engine = engine
        let started = Date()
        runGeneration += 1
        let generation = runGeneration
        let cancelFlag = CancelBox()
        self.cancelFlag = cancelFlag

        samples = []
        sampleCounter = 0
        progress = nil
        lastWriteMBps = 0
        lastReadMBps = 0
        peakMBps = 0
        runningDriveID = snapshot.id
        ownerDriveID = snapshot.id
        runningVolume = volume
        store.benchmarkInProgress = true
        state = .running(.sequentialWrite)

        task = Task {
            do {
                // A dedicated thread, not Task.detached: the engine blocks for
                // the entire run (up to minutes) and must not occupy one of
                // the cooperative pool's core-count threads that long.
                let result = try await Self.runOnDedicatedThread {
                    try engine.run(
                        volume: volume, config: config,
                        isCancelled: { cancelFlag.isSet },
                        progress: { p in
                            Task { @MainActor in
                                self.apply(progress: p, since: started, generation: generation)
                            }
                        })
                }
                try? await history?.record(benchmark: result, driveKey: driveKey)
                finish(.finished(result))
            } catch let error as BenchmarkError where error == .cancelled {
                finish(.idle)
            } catch {
                finish(.failed(error.localizedDescription))
            }
        }
    }

    func cancel() {
        cancelFlag?.trip()
    }

    private static func runOnDedicatedThread(
        _ work: @escaping @Sendable () throws -> BenchmarkResult
    ) async throws -> BenchmarkResult {
        try await withCheckedThrowingContinuation { continuation in
            let thread = Thread {
                continuation.resume(with: Result { try work() })
            }
            thread.name = "com.maclife.mdrivehealth.benchmark"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    /// Return to idle from a finished/failed state (the "Run again" button).
    func reset() {
        guard !isRunning else { return }
        state = .idle
        progress = nil
        samples = []
        lastWriteMBps = 0
        lastReadMBps = 0
        peakMBps = 0
        runningDriveID = nil
        runningVolume = nil
        ownerDriveID = nil
    }

    // MARK: - Private

    private func apply(progress p: BenchmarkProgress, since started: Date,
                       generation: Int) {
        guard generation == runGeneration, isRunning else { return }
        progress = p
        state = .running(p.phase)
        let mbps = p.instantaneousBytesPerSecond / 1e6
        switch p.phase {
        case .sequentialWrite, .randomWrite: lastWriteMBps = mbps
        case .sequentialRead, .randomRead: lastReadMBps = mbps
        }
        peakMBps = max(peakMBps, mbps)
        sampleCounter += 1
        samples.append(SpeedSample(
            id: sampleCounter, phase: p.phase,
            elapsed: Date().timeIntervalSince(started),
            megabytesPerSecond: mbps))
        // Keep the live chart light: past ~800 points, halve by dropping
        // every other sample — the curve's shape survives thinning.
        if samples.count > 800 {
            samples = samples.enumerated()
                .filter { $0.offset.isMultiple(of: 2) }
                .map(\.element)
        }
    }

    private func finish(_ newState: State) {
        store.benchmarkInProgress = false
        runningDriveID = nil
        runningVolume = nil
        progress = nil
        task = nil
        cancelFlag = nil
        state = newState
    }
}

/// Thread-safe cancellation flag shared between a MainActor runner and its
/// dedicated worker thread (Task.isCancelled has no meaning on a raw Thread).
/// Used by both BenchmarkRunner and CapacityVerifyRunner.
final class CancelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func trip() {
        lock.lock(); flag = true; lock.unlock()
    }

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }
}
