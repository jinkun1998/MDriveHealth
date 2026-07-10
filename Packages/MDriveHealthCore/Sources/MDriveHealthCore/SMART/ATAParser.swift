/*
 * ATAParser.swift — parses raw ATA SMART / IDENTIFY structures.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import Foundation

public enum ATAParser {
    /// Parses the 512-byte SMART READ DATA structure (30 × 12-byte attribute
    /// entries at offsets 2...361) plus the optional 512-byte thresholds page.
    public static func parseAttributes(data: [UInt8], thresholds: [UInt8]?,
                                       specs: [UInt8: ATAAttributeSpec]) -> [ATAAttribute] {
        precondition(data.count >= 512)
        var thresholdByID: [UInt8: UInt8] = [:]
        if let thresholds, thresholds.count >= 512 {
            for slot in 0..<30 {
                let offset = 2 + slot * 12
                let id = thresholds[offset]
                guard id != 0 else { continue }
                thresholdByID[id] = thresholds[offset + 1]
            }
        }

        var attributes: [ATAAttribute] = []
        for slot in 0..<30 {
            let offset = 2 + slot * 12
            let id = data[offset]
            guard id != 0 else { continue }
            let flags = UInt16(data[offset + 1]) | (UInt16(data[offset + 2]) << 8)
            let raw = Array(data[(offset + 5)...(offset + 10)])
            let spec = specs[id]
            let format = spec?.format ?? "raw48"
            let (value, display) = ATARawDecoder.decode(raw: raw, format: format)
            attributes.append(ATAAttribute(
                attributeID: id,
                name: spec?.name ?? "Unknown_Attribute",
                flags: flags,
                current: data[offset + 3],
                worst: data[offset + 4],
                threshold: thresholdByID[id],
                rawBytes: raw,
                rawValue: value,
                rawDisplay: display
            ))
        }
        return attributes
    }

    /// Self-test execution status lives at byte 363 of SMART READ DATA.
    public static func parseSelfTestStatus(data: [UInt8]) -> ATASelfTestStatus {
        precondition(data.count >= 512)
        return ATASelfTestStatus(rawByte: data[363])
    }

    /// Parses the 512-byte SMART self-test log (log address 0x06): 21
    /// descriptors of 24 bytes from offset 2, written as a ring buffer whose
    /// most-recent slot index (1-21, 0 = empty log) sits at byte 508.
    /// Returns entries newest-first.
    public static func parseSelfTestLog(_ data: [UInt8]) -> [ATASelfTestLogEntry] {
        precondition(data.count >= 512)
        let mostRecent = Int(data[508])
        guard (1...21).contains(mostRecent) else { return [] }

        var entries: [ATASelfTestLogEntry] = []
        for back in 0..<21 {
            let slot = (mostRecent - 1 - back + 21) % 21
            let offset = 2 + slot * 24
            let testType = data[offset]
            let status = data[offset + 1]
            let hours = UInt64(data[offset + 2]) | (UInt64(data[offset + 3]) << 8)
            guard testType != 0 || status != 0 || hours != 0 else { continue }

            var lba: UInt64 = 0
            for byte in 0..<4 {
                lba |= UInt64(data[offset + 5 + byte]) << (8 * byte)
            }
            let readElementFailed = (status >> 4) == 7
            entries.append(ATASelfTestLogEntry(
                index: back + 1,
                testType: testType,
                statusByte: status,
                powerOnHours: hours,
                failingLBA: readElementFailed ? lba : nil))
        }
        return entries
    }

    /// Parses ATA IDENTIFY DEVICE data (512 bytes, 256 little-endian words;
    /// string bytes are swapped within each word).
    public static func parseIdentify(_ data: [UInt8]) -> ATAIdentifyInfo {
        precondition(data.count >= 512)
        return ATAIdentifyInfo(
            model: identifyString(data, firstWord: 27, wordCount: 20),
            serialNumber: identifyString(data, firstWord: 10, wordCount: 10),
            firmwareRevision: identifyString(data, firstWord: 23, wordCount: 4),
            rotationRate: word(data, 217)
        )
    }

    private static func word(_ data: [UInt8], _ index: Int) -> UInt16 {
        UInt16(data[index * 2]) | (UInt16(data[index * 2 + 1]) << 8)
    }

    private static func identifyString(_ data: [UInt8], firstWord: Int, wordCount: Int) -> String {
        var bytes: [UInt8] = []
        for wordIndex in firstWord..<(firstWord + wordCount) {
            // ATA strings put the first character in the high byte of each word.
            bytes.append(data[wordIndex * 2 + 1])
            bytes.append(data[wordIndex * 2])
        }
        return String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
    }
}
