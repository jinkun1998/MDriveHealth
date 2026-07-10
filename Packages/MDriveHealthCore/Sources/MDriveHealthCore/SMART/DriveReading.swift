/*
 * DriveReading.swift — transport-agnostic probe result + prober.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import Foundation

/// A complete SMART probe of one drive, regardless of transport.
public enum DriveReading: Sendable, Codable, Hashable {
    case nvme(NVMeReading)
    case ata(ATASMARTReading)

    public func evaluateHealth() -> HealthReport {
        switch self {
        case .nvme(let reading): return HealthEvaluator.evaluate(nvme: reading)
        case .ata(let reading): return HealthEvaluator.evaluate(ata: reading)
        }
    }

    public var temperatureCelsius: Int? {
        switch self {
        case .nvme(let reading):
            return reading.smart.temperatureCelsius
        case .ata(let reading):
            let value = reading.attribute(194)?.rawValue ?? reading.attribute(190)?.rawValue
            guard let value, value > 0, value < 120 else { return nil }
            return Int(value)
        }
    }

    public var powerOnHours: UInt64? {
        switch self {
        case .nvme(let reading): return reading.smart.powerOnHours
        case .ata(let reading): return reading.attribute(9)?.rawValue
        }
    }

    public var powerCycles: UInt64? {
        switch self {
        case .nvme(let reading): return reading.smart.powerCycles
        case .ata(let reading): return reading.attribute(12)?.rawValue
        }
    }

    /// Total bytes written by the host, when the drive reports it.
    public var bytesWritten: UInt64? {
        switch self {
        case .nvme(let reading):
            return reading.smart.bytesWritten
        case .ata(let reading):
            guard let written = reading.attribute(241) else { return nil }
            return Self.ataHostBytesWritten(from: written)
        }
    }

    public var capturedAt: Date {
        switch self {
        case .nvme(let reading): return reading.smart.capturedAt
        case .ata(let reading): return reading.capturedAt
        }
    }

    /// Permanent media defects: NVMe media errors; ATA reallocated sectors (5)
    /// + reported uncorrectable (187) + offline uncorrectable (198).
    public var defectCount: UInt64 {
        switch self {
        case .nvme(let reading):
            return reading.smart.mediaErrors
        case .ata(let reading):
            return (reading.attribute(5)?.rawValue ?? 0)
                &+ (reading.attribute(187)?.rawValue ?? 0)
                &+ (reading.attribute(198)?.rawValue ?? 0)
        }
    }

    /// Sectors awaiting reallocation (ATA attribute 197); nil for NVMe.
    public var pendingSectors: UInt64? {
        switch self {
        case .nvme: return nil
        case .ata(let reading): return reading.attribute(197)?.rawValue
        }
    }

    /// The "growing defects" signal used by alerts and risk assessment:
    /// permanent defects plus sectors currently pending reallocation.
    public var dangerousDefectTotal: UInt64 {
        defectCount &+ (pendingSectors ?? 0)
    }

    /// Self-test execution status; nil for NVMe (macOS cannot run NVMe
    /// self-tests) and for ATA drives that did not report one.
    public var ataSelfTest: ATASelfTestStatus? {
        if case .ata(let reading) = self { return reading.selfTest }
        return nil
    }

    public var selfTestInProgress: Bool {
        ataSelfTest?.inProgress == true
    }
}

private extension DriveReading {
    static func ataHostBytesWritten(from attribute: ATAAttribute) -> UInt64? {
        let name = attribute.name.lowercased()

        if name.contains("gib") {
            return attribute.rawValue &* 1_073_741_824
        }
        if name.contains("gb") || name.contains("gigabyte") {
            return attribute.rawValue &* 1_000_000_000
        }
        if name.contains("lba") || name.contains("sector") {
            return attribute.rawValue &* 512
        }

        // The default drivedb entry for attribute 241 is Total_LBAs_Written.
        // Unknown vendor meanings are left nil rather than reporting a
        // confidently wrong write total.
        return attribute.name == "Total_LBAs_Written" ? attribute.rawValue &* 512 : nil
    }
}

/// Outcome of a power-aware probe.
public enum DriveProbeResult: Sendable {
    case reading(DriveReading)
    /// A rotational drive was left spun down instead of being woken.
    case skippedAsleep
}

/// Probes a drive using whichever SMART transport it supports.
public enum DriveProber {
    public static func read(drive: DriveInfo) throws -> DriveReading {
        switch drive.smartInterface {
        case .nvme:
            return .nvme(try NVMeSMARTProvider(drive: drive).read())
        case .ata:
            return .ata(try ATASMARTProvider(drive: drive).read())
        case .unsupported:
            throw SMARTError.unsupportedTransport
        }
    }

    /// Probes honoring a power policy. When `avoidWakingIdle` is true, a
    /// rotational (non-SSD) drive that IOKit reports as spun down is left
    /// asleep rather than being woken by a SMART command — reading the
    /// registry power state never wakes the device, unlike a SMART read.
    /// SSDs and drives of unknown power state are always read.
    public static func probe(drive: DriveInfo,
                             avoidWakingIdle: Bool) throws -> DriveProbeResult {
        if avoidWakingIdle, !drive.isSolidState,
           DrivePower.isLikelyAsleep(registryEntryID: drive.registryEntryID) == true {
            return .skippedAsleep
        }
        return .reading(try read(drive: drive))
    }
}
