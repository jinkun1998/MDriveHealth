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
            // 241 Total_LBAs_Written (512-byte sectors on most drives).
            guard let lbas = reading.attribute(241)?.rawValue else { return nil }
            return lbas &* 512
        }
    }

    public var capturedAt: Date {
        switch self {
        case .nvme(let reading): return reading.smart.capturedAt
        case .ata(let reading): return reading.capturedAt
        }
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
