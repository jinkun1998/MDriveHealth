/*
 * CapacityVerifyRunner.swift — drives CapacityVerifier from the UI: one run
 * at a time, live progress, and the same SMART-poll suppression the speed
 * benchmark uses (both own the disk while running).
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import Foundation
import Observation
import MDriveHealthCore

@MainActor
@Observable
final class CapacityVerifyRunner {
    enum State {
        case idle
        case running(CapacityVerifyPhase)
        case finished(CapacityVerifyResult)
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var progress: CapacityVerifyProgress?
    /// Drive the current/most recent run belongs to (survives finish; cleared
    /// by reset) — keeps results scoped to the right drive's tab.
    private(set) var ownerDriveID: UInt64?
    private(set) var runningVolume: VolumeUsage?

    private let store: DriveStore
    private let verifier = CapacityVerifier()
    private var cancelFlag: CancelBox?
    /// Straggler progress hops from a cancelled run must not touch the next
    /// run's state (same guard BenchmarkRunner uses).
    private var runGeneration = 0

    init(store: DriveStore) { self.store = store }

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    func isBusyElsewhere(driveID: UInt64) -> Bool {
        isRunning && ownerDriveID != nil && ownerDriveID != driveID
    }

    func start(snapshot: DriveSnapshot, volume: VolumeUsage) {
        guard !isRunning else { return }
        let verifier = verifier
        let cancelFlag = CancelBox()
        self.cancelFlag = cancelFlag
        runGeneration += 1
        let generation = runGeneration

        progress = nil
        ownerDriveID = snapshot.id
        runningVolume = volume
        store.benchmarkInProgress = true
        state = .running(.filling)

        Task {
            do {
                let result = try await Self.runOnDedicatedThread {
                    try verifier.run(
                        volume: volume,
                        isCancelled: { cancelFlag.isSet },
                        progress: { p in
                            Task { @MainActor in self.apply(p, generation: generation) }
                        })
                }
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

    func reset() {
        guard !isRunning else { return }
        state = .idle
        progress = nil
        ownerDriveID = nil
        runningVolume = nil
    }

    // MARK: - Private

    private func apply(_ p: CapacityVerifyProgress, generation: Int) {
        guard generation == runGeneration, isRunning else { return }
        progress = p
        state = .running(p.phase)
    }

    private func finish(_ newState: State) {
        store.benchmarkInProgress = false
        runningVolume = nil
        progress = nil
        cancelFlag = nil
        state = newState
    }

    private static func runOnDedicatedThread(
        _ work: @escaping @Sendable () throws -> CapacityVerifyResult
    ) async throws -> CapacityVerifyResult {
        try await withCheckedThrowingContinuation { continuation in
            let thread = Thread {
                continuation.resume(with: Result { try work() })
            }
            thread.name = "com.maclife.mdrivehealth.capacityverify"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }
}
