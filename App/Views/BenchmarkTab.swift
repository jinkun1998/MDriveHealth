/*
 * BenchmarkTab.swift — disk speed benchmark UI: dual live gauges, live chart,
 * result cards, and history. Runs the shared BenchmarkRunner.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import SwiftUI
import Charts
import MDriveHealthCore

struct BenchmarkTab: View {
    let snapshot: DriveSnapshot
    @Environment(DriveStore.self) private var store
    @Environment(BenchmarkRunner.self) private var runner

    @State private var selectedVolumeID: String?
    @State private var fileSize: UInt64 = BenchmarkConfig.defaultFileSize
    @State private var includeRandom = false
    @State private var history: [BenchmarkResult] = []
    @State private var previousForDelta: BenchmarkResult?

    private var selectedVolume: VolumeUsage? {
        snapshot.volumes.first { $0.bsdName == selectedVolumeID } ?? snapshot.volumes.first
    }

    private var config: BenchmarkConfig {
        BenchmarkConfig(fileSizeBytes: fileSize, includeRandomPhases: includeRandom)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if snapshot.volumes.isEmpty {
                    ContentUnavailableView(
                        "Không có volume nào mount trên ổ này",
                        systemImage: "externaldrive.badge.questionmark",
                        description: Text("Benchmark cần một volume đã mount và ghi được. Ổ chưa định dạng hoặc chưa mount thì không đo được."))
                        .frame(maxWidth: .infinity)
                } else if runner.isBusyElsewhere(driveID: snapshot.id) {
                    busyElsewhereBox
                } else {
                    content
                }

                if !history.isEmpty {
                    historySection
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: snapshot.id) { await reloadHistory() }
        .onChange(of: runnerStateID) { Task { await reloadHistory() } }
    }

    // Re-load history whenever a run finishes (state identity flips).
    private var runnerStateID: Int {
        switch runner.state {
        case .idle: return 0
        case .running: return 1
        case .finished: return 2
        case .failed: return 3
        }
    }

    @ViewBuilder
    private var content: some View {
        // finished/failed states belong to the drive that ran the benchmark
        // (runner.ownerDriveID); every other drive's tab shows its own config.
        switch runner.state {
        case .idle:
            // A previous run's numbers are more useful than a bare form.
            if let latest = history.last {
                resultView(latest, live: false)
            }
            configCard
        case .running(let phase):
            runningView(phase: phase)
        case .finished(let result) where runner.ownerDriveID == snapshot.id:
            resultView(result, live: true)
        case .failed(let message) where runner.ownerDriveID == snapshot.id:
            failedBanner(message)
            configCard
        case .finished, .failed:
            if let latest = history.last {
                resultView(latest, live: false)
            }
            configCard
        }
    }

    /// Ring scale in MB/s: the smallest "speed class" tier that fits, so a
    /// 30 MB/s USB stick fills 30% of a 100-tier ring instead of looking as
    /// "full" as a 3000 MB/s NVMe (relative scaling made every drive ~87%).
    private func gaugeScale(for maxMBps: Double) -> Double {
        let tiers: [Double] = [100, 250, 500, 1_000, 2_000, 4_000, 8_000]
        return tiers.first { maxMBps <= $0 } ?? (maxMBps * 1.1)
    }

    // MARK: - Config

    private var configCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Đo tốc độ đọc/ghi")
                .font(.headline)

            Picker("Volume", selection: $selectedVolumeID) {
                ForEach(snapshot.volumes) { volume in
                    Text(String(localized: "benchmark.volumeOption",
                                defaultValue: "\(volume.name) — trống \(Format.bytes(volume.availableBytes))"))
                        .tag(Optional(volume.bsdName))
                }
            }

            Picker("Cỡ dữ liệu đo", selection: $fileSize) {
                ForEach(BenchmarkConfig.presetFileSizes, id: \.self) { size in
                    Text(Format.bytes(size)).tag(size)
                }
            }
            .pickerStyle(.segmented)

            Toggle("Đo thêm Random 4K (~16 giây)", isOn: $includeRandom)

            if let volume = selectedVolume,
               volume.availableBytes < config.requiredFreeBytes {
                Label(String(localized: "benchmark.notEnoughSpace",
                             defaultValue: "Không đủ dung lượng trống trên volume này (cần ~\(Format.bytes(config.requiredFreeBytes)))."),
                      systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            HStack {
                Button {
                    startRun()
                } label: {
                    Label("Bắt đầu đo", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canStart)
                Spacer()
            }

            warningBox
        }
        .padding(14)
        .cardBackground(cornerRadius: 12)
    }

    private var canStart: Bool {
        guard let volume = selectedVolume else { return false }
        return volume.availableBytes >= config.requiredFreeBytes
    }

    private var warningBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(String(localized: "benchmark.warn.write",
                         defaultValue: "Benchmark ghi \(Format.bytes(fileSize)) dữ liệu lên volume rồi tự xoá — tránh dùng ổ nặng trong lúc đo."),
                  systemImage: "info.circle")
            Label("Đo ở độ sâu hàng đợi QD1 (một luồng), nên số thường thấp hơn kết quả Q8T1 của CrystalDiskMark.",
                  systemImage: "gauge.with.dots.needle.33percent")
            if selectedVolume?.mountPoint == "/" {
                Label("Volume khởi động đi qua lớp mã hoá FileVault — kết quả phản ánh tốc độ đã mã hoá.",
                      systemImage: "lock.shield")
            }
            if snapshot.reading?.selfTestInProgress == true {
                Label("Ổ đang chạy SMART self-test — nên đợi test xong để có số chính xác.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: - Running

    private func runningView(phase: BenchmarkPhase) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            gaugeRow(write: liveWriteMBps, read: liveReadMBps, scale: liveScale)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(phaseName(phase)).font(.headline)
                    Spacer()
                    Text(Format.speed((runner.progress?.instantaneousBytesPerSecond ?? 0)))
                        .font(.title3.weight(.semibold).monospacedDigit())
                }
                ProgressView(value: runner.progress?.fractionCompleted ?? 0)
            }

            liveChart

            Button(role: .cancel) {
                runner.cancel()
            } label: {
                Label("Huỷ", systemImage: "stop.fill")
            }
        }
        .padding(14)
        .cardBackground(cornerRadius: 12)
    }

    private var liveChart: some View {
        Chart(runner.samples) { sample in
            LineMark(x: .value("Giây", sample.elapsed),
                     y: .value("MB/s", sample.megabytesPerSecond))
                .foregroundStyle(by: .value("Pha", phaseName(sample.phase)))
                .interpolationMethod(.monotone)
        }
        .chartYAxisLabel("MB/s")
        .chartLegend(.hidden)
        .frame(height: 150)
        .accessibilityLabel(Text("Biểu đồ tốc độ trực tiếp"))
    }

    // Incrementally maintained by the runner — no per-frame array scans.
    private var liveWriteMBps: Double { runner.lastWriteMBps }
    private var liveReadMBps: Double { runner.lastReadMBps }
    private var liveScale: Double { gaugeScale(for: runner.peakMBps) }

    // MARK: - Result

    /// `live: true` = the run that just finished (deltas + "Run again");
    /// `live: false` = a persisted result shown in the idle state.
    private func resultView(_ result: BenchmarkResult, live: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if !live {
                Label("Kết quả gần nhất", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
            }

            gaugeRow(write: result.sequentialWriteBytesPerSec / 1e6,
                     read: result.sequentialReadBytesPerSec / 1e6,
                     scale: gaugeScale(for: max(result.sequentialWriteBytesPerSec,
                                                result.sequentialReadBytesPerSec) / 1e6))

            // Two equal columns → 2×2 with random on, one clean row with it
            // off; never a lone card wrapping to its own line.
            let columns = [GridItem(.flexible(), spacing: 10),
                           GridItem(.flexible(), spacing: 10)]
            LazyVGrid(columns: columns, spacing: 10) {
                resultCard("Tuần tự · Ghi", result.sequentialWriteBytesPerSec,
                           delta: live ? previousForDelta?.sequentialWriteBytesPerSec : nil)
                resultCard("Tuần tự · Đọc", result.sequentialReadBytesPerSec,
                           delta: live ? previousForDelta?.sequentialReadBytesPerSec : nil)
                if let rw = result.randomWriteBytesPerSec {
                    resultCard("Random 4K · Ghi", rw, iops: result.randomWriteIOPS,
                               delta: live ? previousForDelta?.randomWriteBytesPerSec : nil)
                }
                if let rr = result.randomReadBytesPerSec {
                    resultCard("Random 4K · Đọc", rr, iops: result.randomReadIOPS,
                               delta: live ? previousForDelta?.randomReadBytesPerSec : nil)
                }
            }

            Text(String(localized: "benchmark.result.caption",
                        defaultValue: "\(result.volumeName) · \(Format.bytes(result.fileSizeBytes)) · \(result.capturedAt.formatted(date: .abbreviated, time: .shortened))"))
                .font(.caption)
                .foregroundStyle(.secondary)

            if live {
                Button {
                    runner.reset()
                } label: {
                    Label("Chạy lại", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .cardBackground(cornerRadius: 12)
    }

    private func resultCard(_ title: LocalizedStringKey, _ bytesPerSec: Double,
                            iops: Double? = nil, delta: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(Format.speed(bytesPerSec))
                .font(.title3.weight(.semibold).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.7)
            if let iops {
                Text(Format.iops(iops)).font(.caption2).foregroundStyle(.secondary)
            }
            if let delta, delta > 0 {
                let change = (bytesPerSec - delta) / delta
                if abs(change) >= 0.02 {
                    Text(deltaText(change))
                        .font(.caption2)
                        .foregroundStyle(change > 0 ? .green : .orange)
                } else {
                    Text("≈ lần trước").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .cardBackground()
        .accessibilityElement(children: .combine)
    }

    // MARK: - Shared pieces

    private func gaugeRow(write: Double, read: Double, scale: Double) -> some View {
        HStack(spacing: 28) {
            Spacer()
            RingGauge(value: scale > 0 ? write / scale : 0,
                      label: "\(Int(write))", caption: "Ghi (MB/s)", color: .accentColor)
            RingGauge(value: scale > 0 ? read / scale : 0,
                      label: "\(Int(read))", caption: "Đọc (MB/s)", color: .teal)
            Spacer()
        }
    }

    private func failedBanner(_ message: String) -> some View {
        Label(message, systemImage: "xmark.octagon")
            .font(.callout)
            .foregroundStyle(.red)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var busyElsewhereBox: some View {
        Label("Đang chạy benchmark trên ổ khác — đợi xong rồi đo ổ này.",
              systemImage: "hourglass")
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Lịch sử đo").font(.headline)
            VStack(spacing: 0) {
                ForEach(Array(history.reversed().enumerated()), id: \.offset) { index, result in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(result.capturedAt.formatted(date: .abbreviated, time: .shortened))
                            Text(String(localized: "benchmark.history.sub",
                                        defaultValue: "\(result.volumeName) · \(Format.bytes(result.fileSizeBytes))"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(String(localized: "benchmark.history.wr",
                                    defaultValue: "W \(Int(result.sequentialWriteBytesPerSec / 1e6)) · R \(Int(result.sequentialReadBytesPerSec / 1e6)) MB/s"))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    if index < history.count - 1 { Divider() }
                }
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: - Actions

    private func startRun() {
        guard let volume = selectedVolume else { return }
        // Delta baseline must be a comparable run: same volume, same test
        // size, same random setting — else a 512 MB run gets compared against
        // a 5 GB run on another volume and the badge lies.
        let runConfig = config
        previousForDelta = history.last { previous in
            previous.volumeBSDName == volume.bsdName
                && previous.fileSizeBytes == runConfig.fileSizeBytes
                && (previous.randomWriteBytesPerSec != nil) == runConfig.includeRandomPhases
        }
        runner.start(snapshot: snapshot, volume: volume, config: runConfig)
    }

    private func reloadHistory() async {
        // Reset a selection carried over from another drive (the view keeps
        // its @State across drive switches via positional identity).
        if selectedVolumeID == nil
            || !snapshot.volumes.contains(where: { $0.bsdName == selectedVolumeID }) {
            selectedVolumeID = snapshot.volumes.first?.bsdName
        }
        let key = HistoryStore.driveKey(for: snapshot.drive)
        history = (try? await store.history?.benchmarks(driveKey: key, since: .distantPast)) ?? []
    }

    private func deltaText(_ change: Double) -> String {
        let pct = Int((abs(change) * 100).rounded())
        return change > 0
            ? String(localized: "benchmark.delta.up", defaultValue: "▲ \(pct)% nhanh hơn lần trước")
            : String(localized: "benchmark.delta.down", defaultValue: "▼ \(pct)% chậm hơn lần trước")
    }

    private func phaseName(_ phase: BenchmarkPhase) -> String {
        switch phase {
        case .sequentialWrite: return String(localized: "benchmark.phase.seqWrite", defaultValue: "Ghi tuần tự")
        case .sequentialRead: return String(localized: "benchmark.phase.seqRead", defaultValue: "Đọc tuần tự")
        case .randomWrite: return String(localized: "benchmark.phase.randWrite", defaultValue: "Ghi Random 4K")
        case .randomRead: return String(localized: "benchmark.phase.randRead", defaultValue: "Đọc Random 4K")
        }
    }
}
