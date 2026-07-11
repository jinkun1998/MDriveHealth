/*
 * ShareCards.swift — social-friendly PNG cards for benchmark / capacity
 * results. Facebook groups are image-first: a branded card travels much
 * further than pasted text.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import SwiftUI
import MDriveHealthCore

/// Renders a card view into a temp PNG the system share sheet can take.
@MainActor
enum ShareCardRenderer {
    static func pngURL(for view: some View, name: String) -> URL? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cgImage = renderer.cgImage else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name).png")
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}

/// Fixed-appearance (always light) card — the PNG must look right no matter
/// the poster's theme.
struct BenchmarkShareCard: View {
    let drive: DriveInfo
    let health: HealthReport?
    let result: BenchmarkResult

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("MDriveHealth", systemImage: "internaldrive.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Text(result.capturedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color.accentColor)

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(drive.model)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.black)
                        Text(verbatim: "\(Format.bytes(drive.sizeBytes)) · \(drive.isSolidState ? "SSD" : "HDD") · \(drive.interconnect) · \(result.volumeName)")
                            .font(.callout)
                            .foregroundStyle(.gray)
                    }
                    Spacer()
                    if let health {
                        Text(health.rating.displayName)
                            .font(.callout.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(health.rating.color, in: Capsule())
                    }
                }

                HStack(spacing: 12) {
                    shareStat("Ghi tuần tự", result.sequentialWriteBytesPerSec)
                    shareStat("Đọc tuần tự", result.sequentialReadBytesPerSec)
                    if let rw = result.randomWriteBytesPerSec {
                        shareStat("Random 4K Ghi", rw)
                    }
                    if let rr = result.randomReadBytesPerSec {
                        shareStat("Random 4K Đọc", rr)
                    }
                }

                Text(String(localized: "share.footer",
                            defaultValue: "Đo bằng MDriveHealth (QD1, \(Format.bytes(result.fileSizeBytes))) — app sức khoẻ ổ đĩa miễn phí cho cộng đồng Maclife 🇻🇳"))
                    .font(.caption)
                    .foregroundStyle(.gray)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
        }
        .frame(width: 640)
        .background(Color.white)
    }

    private func shareStat(_ title: LocalizedStringKey, _ bytesPerSec: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.gray)
            Text(Format.speed(bytesPerSec))
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(.black)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(white: 0.955), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct CapacityShareCard: View {
    let drive: DriveInfo
    let result: CapacityVerifyResult

    private var isFake: Bool { result.verdict == .fake }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("MDriveHealth", systemImage: "internaldrive.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Text(result.capturedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(isFake ? Color.red : Color.green)

            VStack(alignment: .leading, spacing: 12) {
                Text(drive.model)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.black)
                Text(verbatim: "\(Format.bytes(drive.sizeBytes)) · \(result.volumeName)")
                    .font(.callout)
                    .foregroundStyle(.gray)

                Label(isFake ? "PHÁT HIỆN Ổ FAKE DUNG LƯỢNG"
                             : "DUNG LƯỢNG THẬT — không phát hiện gian lận",
                      systemImage: isFake ? "xmark.seal.fill" : "checkmark.seal.fill")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(isFake ? .red : .green)

                Text(isFake
                     ? String(localized: "share.capacity.fake",
                              defaultValue: "Chỉ ~\(Format.bytes(result.firstCorruptionOffset ?? 0)) lưu được thật sự trong \(Format.bytes(result.bytesWritten)) đã kiểm tra.")
                     : String(localized: "share.capacity.genuine",
                              defaultValue: "Đã ghi & xác minh \(Format.bytes(result.bytesWritten)) — dữ liệu khớp 100%."))
                    .font(.callout)
                    .foregroundStyle(.black)

                Text(String(localized: "share.capacity.footer",
                            defaultValue: "Kiểm tra kiểu H2testw bằng MDriveHealth — app sức khoẻ ổ đĩa miễn phí cho cộng đồng Maclife 🇻🇳"))
                    .font(.caption)
                    .foregroundStyle(.gray)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
        }
        .frame(width: 640)
        .background(Color.white)
    }
}
