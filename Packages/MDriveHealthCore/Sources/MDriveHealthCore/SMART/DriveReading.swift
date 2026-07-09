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
}
