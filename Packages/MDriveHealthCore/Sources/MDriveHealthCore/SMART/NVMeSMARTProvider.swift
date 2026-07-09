/*
 * NVMeSMARTProvider.swift — reads NVMe identify + SMART data through CSMART.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import Foundation
import IOKit
import CSMART

public struct NVMeSMARTProvider: Sendable {
    public let registryEntryID: UInt64

    public init(registryEntryID: UInt64) {
        self.registryEntryID = registryEntryID
    }

    public init(drive: DriveInfo) {
        self.init(registryEntryID: drive.registryEntryID)
    }

    public func read() throws -> NVMeReading {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IORegistryEntryIDMatching(registryEntryID))
        guard service != 0 else { throw SMARTError.serviceNotFound }
        defer { IOObjectRelease(service) }

        var sessionPtr: OpaquePointer?
        let created = MDNVMeSessionCreate(service, &sessionPtr)
        guard created == KERN_SUCCESS, let session = sessionPtr else {
            throw SMARTError.ioKit(created, "MDNVMeSessionCreate")
        }
        defer { MDNVMeSessionDestroy(session) }

        var rawLog = MDNVMeSMARTLog()
        let logResult = MDNVMeReadSMARTLog(session, &rawLog)
        guard logResult == KERN_SUCCESS else {
            throw SMARTError.ioKit(logResult, "MDNVMeReadSMARTLog")
        }

        var rawIdentify = MDNVMeIdentifyController()
        let identifyResult = MDNVMeReadIdentify(session, &rawIdentify, 0)
        guard identifyResult == KERN_SUCCESS else {
            throw SMARTError.ioKit(identifyResult, "MDNVMeReadIdentify")
        }

        return NVMeReading(
            controller: Self.decode(identify: rawIdentify),
            smart: Self.decode(log: rawLog)
        )
    }

    static func decode(identify id: MDNVMeIdentifyController) -> NVMeControllerInfo {
        let version: String?
        if id.ver != 0 {
            version = "\(id.ver >> 16).\((id.ver >> 8) & 0xFF).\(id.ver & 0xFF)"
        } else {
            version = nil
        }
        let oui = withUnsafeBytes(of: id.ieee) { raw in
            String(format: "%02X-%02X-%02X", raw[2], raw[1], raw[0])
        }
        return NVMeControllerInfo(
            model: fixedString(id.modelNumber),
            serialNumber: fixedString(id.serialNumber),
            firmwareRevision: fixedString(id.firmwareRevision),
            ieeeOUI: oui,
            controllerID: id.cntlid,
            specVersion: version,
            totalCapacityBytes: leUInt64(id.tnvmcap),
            unallocatedCapacityBytes: leUInt64(id.unvmcap),
            warningTempKelvin: id.wctemp,
            criticalTempKelvin: id.cctemp,
            namespaceCount: id.nn
        )
    }

    static func decode(log: MDNVMeSMARTLog) -> NVMeSMARTSnapshot {
        let sensors = withUnsafeBytes(of: log.temperatureSensor) { raw in
            (0..<8).map { UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: UInt16.self)) }
        }
        let temperature = withUnsafeBytes(of: log.temperature) { raw in
            UInt16(littleEndian: raw.loadUnaligned(as: UInt16.self))
        }
        return NVMeSMARTSnapshot(
            capturedAt: Date(),
            criticalWarning: NVMeCriticalWarning(rawValue: log.criticalWarning),
            temperatureKelvin: temperature,
            availableSpare: log.availableSpare,
            availableSpareThreshold: log.availableSpareThreshold,
            percentageUsed: log.percentageUsed,
            dataUnitsRead: leUInt64(log.dataUnitsRead),
            dataUnitsWritten: leUInt64(log.dataUnitsWritten),
            hostReadCommands: leUInt64(log.hostReadCommands),
            hostWriteCommands: leUInt64(log.hostWriteCommands),
            controllerBusyTimeMinutes: leUInt64(log.controllerBusyTime),
            powerCycles: leUInt64(log.powerCycles),
            powerOnHours: leUInt64(log.powerOnHours),
            unsafeShutdowns: leUInt64(log.unsafeShutdowns),
            mediaErrors: leUInt64(log.mediaErrors),
            errorLogEntries: leUInt64(log.errorLogEntries),
            warningTempTimeMinutes: log.warningTempTime,
            criticalTempTimeMinutes: log.criticalCompTime,
            temperatureSensorsKelvin: sensors
        )
    }
}

/// Decodes a fixed-size C char array (imported as a tuple) holding a
/// space-padded ASCII string, as used in NVMe identify data.
func fixedString<T>(_ value: T) -> String {
    withUnsafeBytes(of: value) { raw in
        String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
    }
}

/// Reads the low 64 bits of a little-endian fixed-size byte array (imported as
/// a tuple), as used for the 128-bit counters in NVMe structures.
func leUInt64<T>(_ value: T) -> UInt64 {
    withUnsafeBytes(of: value) { raw in
        UInt64(littleEndian: raw.loadUnaligned(as: UInt64.self))
    }
}
