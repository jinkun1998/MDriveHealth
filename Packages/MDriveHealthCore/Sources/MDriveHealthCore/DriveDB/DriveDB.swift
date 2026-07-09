/*
 * DriveDB.swift — drive-specific ATA attribute database, generated from
 * smartmontools drivedb.h (GPL-2.0-or-later) by tools/convert_drivedb.py.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import Foundation

/// How to decode and label one ATA SMART attribute for a matched drive.
public struct ATAAttributeSpec: Codable, Sendable, Hashable {
    public let format: String
    public let byteorder: String?
    public let name: String?
    /// "HDD" or "SSD" when the override only applies to that medium.
    public let onlyFor: String?

    public init(format: String, byteorder: String? = nil, name: String? = nil,
                onlyFor: String? = nil) {
        self.format = format
        self.byteorder = byteorder
        self.name = name
        self.onlyFor = onlyFor
    }
}

public struct DriveDBEntry: Codable, Sendable {
    public let family: String
    public let model: String
    public let firmware: String?
    public let warning: String?
    public let attrs: [String: ATAAttributeSpec]?
    public let firmwareFixes: [String]?
}

/// Result of matching a drive against the database: merged attribute specs
/// (defaults overlaid with the entry's vendor-specific presets).
public struct DriveDBMatch: Sendable {
    public let family: String?
    public let warning: String?
    public let specs: [UInt8: ATAAttributeSpec]
}

public final class DriveDB: @unchecked Sendable {
    public static let shared: DriveDB = {
        do { return try DriveDB() } catch {
            fatalError("drivedb.json bundled resource is invalid: \(error)")
        }
    }()

    public let version: String
    public let entries: [DriveDBEntry]
    private let defaults: [UInt8: ATAAttributeSpec]

    private let lock = NSLock()
    private var regexCache: [Int: NSRegularExpression?] = [:]

    private struct File: Codable {
        let drivedbVersion: String
        let defaults: [String: ATAAttributeSpec]
        let entries: [DriveDBEntry]
    }

    public init() throws {
        guard let url = Bundle.module.url(forResource: "drivedb", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        self.version = file.drivedbVersion
        self.entries = file.entries
        self.defaults = Self.byAttributeID(file.defaults)
    }

    /// Matches like smartmontools: first entry whose model regex (and firmware
    /// regex, when present) full-matches wins.
    public func match(model: String, firmware: String?, isSSD: Bool) -> DriveDBMatch {
        var merged = defaults
        for (index, entry) in entries.enumerated() {
            guard let modelRegex = regex(for: index * 2, pattern: entry.model),
                  fullMatch(modelRegex, model) else { continue }
            if let firmwarePattern = entry.firmware, !firmwarePattern.isEmpty {
                guard let firmware,
                      let fwRegex = regex(for: index * 2 + 1, pattern: firmwarePattern),
                      fullMatch(fwRegex, firmware) else { continue }
            }
            for (id, spec) in Self.byAttributeID(entry.attrs ?? [:]) {
                if let only = spec.onlyFor, (only == "SSD") != isSSD { continue }
                merged[id] = spec
            }
            return DriveDBMatch(family: entry.family, warning: entry.warning, specs: merged)
        }
        return DriveDBMatch(family: nil, warning: nil, specs: merged)
    }

    /// Default attribute table (no model match), still medium-aware.
    public func defaultSpecs() -> [UInt8: ATAAttributeSpec] { defaults }

    private static func byAttributeID(_ raw: [String: ATAAttributeSpec]) -> [UInt8: ATAAttributeSpec] {
        var result: [UInt8: ATAAttributeSpec] = [:]
        for (key, spec) in raw {
            if let id = UInt8(key) { result[id] = spec }
        }
        return result
    }

    private func regex(for key: Int, pattern: String) -> NSRegularExpression? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = regexCache[key] { return cached }
        // drivedb regexes are POSIX ERE that must match the full string.
        let regex = try? NSRegularExpression(pattern: "^(?:\(pattern))$", options: [])
        regexCache[key] = regex
        return regex
    }

    private func fullMatch(_ regex: NSRegularExpression, _ string: String) -> Bool {
        let range = NSRange(string.startIndex..., in: string)
        return regex.firstMatch(in: string, options: [], range: range) != nil
    }
}
