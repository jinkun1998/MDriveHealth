/*
 * SensorsReader.swift — temperature sensors via IOHIDEventSystemClient
 * (Apple Silicon). Best-effort: returns an empty list when unavailable.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import Foundation
import CSMART

public struct TemperatureSensor: Sendable, Codable, Hashable, Identifiable {
    public let name: String
    public let celsius: Double
    public var id: String { name }
}

public enum SensorsReader {
    /// Reads all HID temperature sensors (SOC, NAND, battery... on M-series).
    public static func readTemperatures() -> [TemperatureSensor] {
        guard let unmanagedClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else {
            return []
        }
        let client = unmanagedClient.takeRetainedValue()
        let matching: [String: Int] = [
            "PrimaryUsagePage": Int(kMDHIDUsagePageAppleVendor),
            "PrimaryUsage": Int(kMDHIDUsageAppleVendorTemperatureSensor),
        ]
        IOHIDEventSystemClientSetMatching(client, matching as CFDictionary)
        guard let services = IOHIDEventSystemClientCopyServices(client) as NSArray?
        else { return [] }

        var sensors: [TemperatureSensor] = []
        for element in services {
            let service = element as! IOHIDServiceClient
            let value = MDHIDServiceReadTemperature(service)
            guard value > 0, value < 130 else { continue }
            let name = (IOHIDServiceClientCopyProperty(
                service, "Product" as CFString) as? String) ?? "Sensor"
            sensors.append(TemperatureSensor(name: name, celsius: value))
        }
        return sensors.sorted { $0.name < $1.name }
    }

    /// Groups raw sensors into human-friendly buckets and averages them.
    public static func summarize(_ sensors: [TemperatureSensor])
        -> [(group: String, celsius: Double)] {
        var buckets: [String: [Double]] = [:]
        for sensor in sensors {
            let name = sensor.name.lowercased()
            let group: String
            if name.contains("pmu") && name.contains("tdie") { group = "CPU/SOC" }
            else if name.contains("soc") || name.contains("cpu") { group = "CPU/SOC" }
            else if name.contains("gpu") { group = "GPU" }
            else if name.contains("nand") || name.contains("ans") { group = "SSD (NAND)" }
            else if name.contains("batt") || name.contains("gas gauge") { group = "Pin" }
            else if name.contains("pmgr") || name.contains("power") { group = "Nguồn" }
            else { group = "Khác" }
            buckets[group, default: []].append(sensor.celsius)
        }
        let order = ["CPU/SOC", "GPU", "SSD (NAND)", "Pin", "Nguồn", "Khác"]
        return order.compactMap { group in
            guard let values = buckets[group], !values.isEmpty else { return nil }
            return (group, values.reduce(0, +) / Double(values.count))
        }
    }
}
