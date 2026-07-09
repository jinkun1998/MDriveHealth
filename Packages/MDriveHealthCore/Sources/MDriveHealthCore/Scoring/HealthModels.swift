/*
 * HealthModels.swift — health report models.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import Foundation

public enum HealthRating: String, Sendable, Codable, CaseIterable, Comparable {
    case good, ok, warning, failing, failed

    private var rank: Int {
        switch self {
        case .good: return 0
        case .ok: return 1
        case .warning: return 2
        case .failing: return 3
        case .failed: return 4
        }
    }

    public static func < (lhs: HealthRating, rhs: HealthRating) -> Bool {
        lhs.rank < rhs.rank
    }

    /// The worse (more severe) of two ratings.
    public static func worst(_ lhs: HealthRating, _ rhs: HealthRating) -> HealthRating {
        max(lhs, rhs)
    }
}

public enum IssueSeverity: String, Sendable, Codable, Comparable {
    case info, advisory, warning, critical

    private var rank: Int {
        switch self {
        case .info: return 0
        case .advisory: return 1
        case .warning: return 2
        case .critical: return 3
        }
    }

    public static func < (lhs: IssueSeverity, rhs: IssueSeverity) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// One concrete problem/observation found while evaluating a drive.
public struct HealthIssue: Sendable, Codable, Hashable, Identifiable {
    /// Stable key for localization/dedup, e.g. "ata.5.reallocated", "nvme.spare".
    public let id: String
    public let severity: IssueSeverity
    public let title: String
    public let detail: String
    public let attributeID: UInt8?

    public init(id: String, severity: IssueSeverity, title: String, detail: String,
                attributeID: UInt8? = nil) {
        self.id = id
        self.severity = severity
        self.title = title
        self.detail = detail
        self.attributeID = attributeID
    }
}

/// DriveDX-style overall verdict for one drive.
public struct HealthReport: Sendable, Codable, Hashable {
    /// 0...100, higher is healthier.
    public let score: Int
    public let rating: HealthRating
    /// Estimated SSD endurance remaining; nil for HDDs/unknown.
    public let lifetimeLeftPercent: Int?
    /// Sorted most severe first.
    public let issues: [HealthIssue]
    public let capturedAt: Date
}
