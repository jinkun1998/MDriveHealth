/*
 * IOErrorWatcher.swift — scans the unified log for kernel disk I/O errors.
 * Best-effort: requires the user to be in the admin group; failures return [].
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import Foundation

public struct IOErrorEvent: Sendable, Codable, Hashable {
    public let date: Date
    public let message: String

    public init(date: Date, message: String) {
        self.date = date
        self.message = message
    }

    /// True when the message references the device itself or one of its
    /// partitions ("disk1", "disk1s2") — but not a longer device name that
    /// merely shares the prefix ("disk10"), nor a substring like "rdisk1".
    /// The single definition of "this log line concerns this BSD device",
    /// used both to narrow the log query and to count per device.
    public func mentions(_ bsdName: String) -> Bool {
        guard !bsdName.isEmpty else { return false }
        var search = message.startIndex..<message.endIndex
        while let found = message.range(of: bsdName, range: search) {
            let followedByDigit = found.upperBound < message.endIndex
                && message[found.upperBound].isNumber
            let precededByAlphanumeric = found.lowerBound > message.startIndex && {
                let previous = message[message.index(before: found.lowerBound)]
                return previous.isLetter || previous.isNumber
            }()
            if !followedByDigit, !precededByAlphanumeric { return true }
            search = found.upperBound..<message.endIndex
        }
        return false
    }
}

public enum IOErrorWatcher {
    /// Returns kernel log lines mentioning I/O errors within the window.
    /// `bsdName` (e.g. "disk0") narrows results to one device when given.
    public static func recentErrors(withinMinutes minutes: Int,
                                    bsdName: String? = nil,
                                    timeout: TimeInterval = 20) -> [IOErrorEvent] {
        var predicate = """
            process == "kernel" AND (eventMessage CONTAINS[c] "I/O error" \
            OR eventMessage CONTAINS[c] "read error" \
            OR eventMessage CONTAINS[c] "write error")
            """
        if let bsdName, !bsdName.isEmpty {
            let escapedName = bsdName.replacingOccurrences(of: "\"", with: "\\\"")
            predicate += " AND eventMessage CONTAINS \"\(escapedName)\""
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "show", "--last", "\(minutes)m", "--style", "ndjson",
            "--predicate", predicate,
        ]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return []
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if process.isRunning {
                process.terminate()
            }
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"

        var events: [IOErrorEvent] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)),
                  let dict = object as? [String: Any],
                  let message = dict["eventMessage"] as? String
            else { continue }
            let event = IOErrorEvent(
                date: (dict["timestamp"] as? String).flatMap(formatter.date(from:)) ?? Date(),
                message: message)
            // The log predicate's CONTAINS narrows cheaply but matches
            // "disk10" for "disk1"; apply the exact device match here so the
            // filtered form agrees with per-device counting.
            if let bsdName, !bsdName.isEmpty, !event.mentions(bsdName) { continue }
            events.append(event)
        }
        return events
    }
}
