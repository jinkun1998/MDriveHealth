/*
 * HealthEvaluator.swift — deterministic DriveDX-style drive health scoring.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import Foundation

public enum HealthEvaluator {

    // MARK: - NVMe

    public static func evaluate(nvme reading: NVMeReading) -> HealthReport {
        var issues: [HealthIssue] = []
        var deduction = 0
        var ratingCap = HealthRating.good
        let smart = reading.smart
        let warning = smart.criticalWarning

        if warning.contains(.mediaReadOnly) {
            issues.append(.init(id: "nvme.readonly", severity: .critical,
                                title: "Media in read-only mode",
                                detail: "The controller has locked the media read-only. Back up immediately and replace the drive."))
            deduction += 60
            ratingCap = .failed
        }
        if warning.contains(.reliabilityDegraded) {
            issues.append(.init(id: "nvme.reliability", severity: .critical,
                                title: "NVM subsystem reliability degraded",
                                detail: "The controller reports degraded reliability due to media or internal errors."))
            deduction += 50
            ratingCap = HealthRating.worst(ratingCap, .failing)
        }
        let spareLow = warning.contains(.spareBelowThreshold)
            || (smart.availableSpareThreshold > 0
                && smart.availableSpare < smart.availableSpareThreshold)
        if spareLow {
            issues.append(.init(id: "nvme.spare", severity: .critical,
                                title: "Available spare below threshold",
                                detail: "Spare blocks \(smart.availableSpare)% are below the \(smart.availableSpareThreshold)% threshold. The drive is running out of reserve capacity."))
            deduction += 40
            ratingCap = HealthRating.worst(ratingCap, .failing)
        }
        if warning.contains(.temperatureError) {
            issues.append(.init(id: "nvme.temperature.warning-bit", severity: .warning,
                                title: "Temperature outside thresholds",
                                detail: "The controller reports operation outside its temperature thresholds."))
            deduction += 10
        }
        if warning.contains(.volatileBackupFailed) {
            issues.append(.init(id: "nvme.backup", severity: .warning,
                                title: "Volatile memory backup failed",
                                detail: "The power-loss protection backup device has failed."))
            deduction += 15
        }
        if warning.contains(.persistentMemoryReadOnly) {
            issues.append(.init(id: "nvme.pmr", severity: .warning,
                                title: "Persistent memory region unreliable",
                                detail: "The persistent memory region is read-only or unreliable."))
            deduction += 20
        }

        // Endurance (wear).
        let used = Int(smart.percentageUsed)
        let lifetimeLeft = max(0, 100 - min(100, used))
        switch used {
        case 100...:
            issues.append(.init(id: "nvme.wear.exhausted", severity: .warning,
                                title: "Rated endurance exhausted",
                                detail: "Vendor wear estimate is \(used)%. The drive exceeded its rated endurance; it may keep working but plan replacement."))
            deduction += 20
        case 90...:
            issues.append(.init(id: "nvme.wear.high", severity: .advisory,
                                title: "Endurance nearly exhausted",
                                detail: "Vendor wear estimate is \(used)% of rated endurance."))
            deduction += 10
        case 80...:
            deduction += 5
        default:
            break
        }

        if smart.mediaErrors > 0 {
            let severity: IssueSeverity = smart.mediaErrors > 10 ? .critical : .warning
            issues.append(.init(id: "nvme.media-errors", severity: severity,
                                title: "Media integrity errors",
                                detail: "\(smart.mediaErrors) unrecovered data-integrity errors have occurred."))
            deduction += smart.mediaErrors > 100 ? 25 : (smart.mediaErrors > 10 ? 15 : 8)
            if severity == .critical { ratingCap = HealthRating.worst(ratingCap, .failing) }
        }

        // Live temperature vs identify thresholds.
        let temp = smart.temperatureKelvin
        let critical = reading.controller.criticalTempKelvin
        let warn = reading.controller.warningTempKelvin
        if critical > 0, temp >= critical {
            issues.append(.init(id: "nvme.temperature.critical", severity: .critical,
                                title: "Temperature at critical level",
                                detail: "Composite temperature \(smart.temperatureCelsius)°C reached the critical threshold \(Int(critical) - 273)°C."))
            deduction += 15
        } else if warn > 0, temp >= warn {
            issues.append(.init(id: "nvme.temperature.high", severity: .warning,
                                title: "Temperature above warning threshold",
                                detail: "Composite temperature \(smart.temperatureCelsius)°C exceeds the warning threshold \(Int(warn) - 273)°C."))
            deduction += 8
        }

        return report(deduction: deduction, ratingCap: ratingCap, issues: issues,
                      lifetimeLeft: lifetimeLeft, capturedAt: smart.capturedAt)
    }

    // MARK: - ATA

    public static func evaluate(ata reading: ATASMARTReading) -> HealthReport {
        var issues: [HealthIssue] = []
        var deduction = 0
        var ratingCap = HealthRating.good
        let isSSD = reading.identify?.isSolidState ?? false

        if reading.overallFailurePredicted == true {
            issues.append(.init(id: "ata.smart-status", severity: .critical,
                                title: "SMART overall status: FAILING",
                                detail: "The drive itself predicts failure (thresholds exceeded). Back up immediately."))
            deduction += 50
            ratingCap = .failing
        }

        for attribute in reading.attributes {
            if attribute.failedNow, attribute.isPrefail {
                issues.append(.init(id: "ata.\(attribute.attributeID).tripped", severity: .critical,
                                    title: "\(attribute.name) below failure threshold",
                                    detail: "Pre-fail attribute \(attribute.attributeID) (\(attribute.name)) value \(attribute.current) is at or below threshold \(attribute.threshold ?? 0). Failure is predicted.",
                                    attributeID: attribute.attributeID))
                deduction += 40
                ratingCap = HealthRating.worst(ratingCap, .failing)
            } else if attribute.failedEver, attribute.isPrefail {
                issues.append(.init(id: "ata.\(attribute.attributeID).tripped-past", severity: .warning,
                                    title: "\(attribute.name) failed in the past",
                                    detail: "Pre-fail attribute \(attribute.attributeID) (\(attribute.name)) dropped to \(attribute.worst), at or below threshold \(attribute.threshold ?? 0), at some point.",
                                    attributeID: attribute.attributeID))
                deduction += 10
            }

            let raw = attribute.rawValue
            switch attribute.attributeID {
            case 5, 196: // reallocated sectors / reallocation events
                guard raw > 0 else { break }
                let isEvents = attribute.attributeID == 196
                let severity: IssueSeverity = raw >= 50 ? .critical : (raw >= 5 ? .warning : .advisory)
                issues.append(.init(id: "ata.\(attribute.attributeID).raw", severity: severity,
                                    title: isEvents ? "Reallocation events recorded" : "Reallocated sectors present",
                                    detail: "\(attribute.name) raw count is \(raw). Grown defects indicate media degradation.",
                                    attributeID: attribute.attributeID))
                let base = isEvents ? [3, 6, 14] : [10, 20, 35]
                deduction += raw >= 50 ? base[2] : (raw >= 5 ? base[1] : base[0])
                if severity == .critical { ratingCap = HealthRating.worst(ratingCap, .failing) }
            case 197: // current pending sectors
                guard raw > 0 else { break }
                let severity: IssueSeverity = raw >= 5 ? .critical : .warning
                issues.append(.init(id: "ata.197.raw", severity: severity,
                                    title: "Pending (unstable) sectors",
                                    detail: "\(raw) sectors are waiting to be remapped. Data in them may be unreadable.",
                                    attributeID: 197))
                deduction += raw >= 50 ? 40 : (raw >= 5 ? 25 : 15)
                if severity == .critical { ratingCap = HealthRating.worst(ratingCap, .failing) }
            case 198: // offline uncorrectable
                guard raw > 0 else { break }
                let severity: IssueSeverity = raw >= 10 ? .critical : .warning
                issues.append(.init(id: "ata.198.raw", severity: severity,
                                    title: "Uncorrectable sectors",
                                    detail: "\(raw) sectors could not be read/corrected during offline scans.",
                                    attributeID: 198))
                deduction += raw >= 10 ? 30 : 15
                if severity == .critical { ratingCap = HealthRating.worst(ratingCap, .failing) }
            case 187: // reported uncorrectable errors
                guard raw > 0 else { break }
                let severity: IssueSeverity = raw >= 100 ? .critical : .warning
                issues.append(.init(id: "ata.187.raw", severity: severity,
                                    title: "Reported uncorrectable errors",
                                    detail: "\(raw) errors could not be recovered by ECC.",
                                    attributeID: 187))
                deduction += raw >= 100 ? 30 : (raw >= 10 ? 20 : 10)
                if severity == .critical { ratingCap = HealthRating.worst(ratingCap, .failing) }
            case 10: // spin retry
                guard raw > 0, !isSSD else { break }
                let severity: IssueSeverity = raw >= 10 ? .critical : .warning
                issues.append(.init(id: "ata.10.raw", severity: severity,
                                    title: "Spin-up retries",
                                    detail: "The spindle needed \(raw) retries to reach speed — possible mechanical/power issue.",
                                    attributeID: 10))
                deduction += raw >= 10 ? 30 : 15
                if severity == .critical { ratingCap = HealthRating.worst(ratingCap, .failing) }
            case 184: // end-to-end error
                guard raw > 0 else { break }
                let severity: IssueSeverity = raw >= 10 ? .critical : .warning
                issues.append(.init(id: "ata.184.raw", severity: severity,
                                    title: "End-to-End errors",
                                    detail: "\(raw) data-path parity errors between cache and media.",
                                    attributeID: 184))
                deduction += raw >= 10 ? 35 : 20
                if severity == .critical { ratingCap = HealthRating.worst(ratingCap, .failing) }
            case 188: // command timeout
                guard raw >= 100 else { break }
                issues.append(.init(id: "ata.188.raw", severity: .warning,
                                    title: "Command timeouts",
                                    detail: "\(raw) commands timed out — can indicate cabling or controller trouble.",
                                    attributeID: 188))
                deduction += raw >= 10_000 ? 20 : 10
            case 199: // UDMA CRC
                guard raw > 0 else { break }
                issues.append(.init(id: "ata.199.raw", severity: raw >= 10 ? .warning : .advisory,
                                    title: "Interface CRC errors",
                                    detail: "\(raw) CRC errors on the SATA link — usually a cable/connector problem, not the drive itself.",
                                    attributeID: 199))
                deduction += raw >= 10 ? 8 : 3
            default:
                break
            }
        }

        // SSD endurance from normalized values, first matching wear attribute.
        var lifetimeLeft: Int?
        if isSSD {
            let wearAttributeIDs: [UInt8] = [231, 233, 169, 202, 177, 173]
            for id in wearAttributeIDs {
                if let attr = reading.attribute(id) {
                    lifetimeLeft = min(100, max(0, Int(attr.current)))
                    break
                }
            }
            if let left = lifetimeLeft {
                if left <= 0 {
                    issues.append(.init(id: "ata.wear.exhausted", severity: .warning,
                                        title: "Rated endurance exhausted",
                                        detail: "The SSD wear indicator reports no rated endurance left."))
                    deduction += 20
                } else if left <= 10 {
                    issues.append(.init(id: "ata.wear.high", severity: .advisory,
                                        title: "Endurance nearly exhausted",
                                        detail: "About \(left)% of rated endurance remains."))
                    deduction += 10
                } else if left <= 20 {
                    deduction += 5
                }
            }
        }

        // Temperature from 194 (or 190 airflow) primary value.
        let temperature = reading.attribute(194)?.rawValue ?? reading.attribute(190)?.rawValue
        if let temp = temperature, temp > 0, temp < 120 {
            let (warnAt, criticalAt): (UInt64, UInt64) = isSSD ? (70, 80) : (55, 65)
            if temp >= criticalAt {
                issues.append(.init(id: "ata.temperature.critical", severity: .critical,
                                    title: "Temperature critically high",
                                    detail: "Drive temperature is \(temp)°C."))
                deduction += 15
            } else if temp >= warnAt {
                issues.append(.init(id: "ata.temperature.high", severity: .warning,
                                    title: "Temperature high",
                                    detail: "Drive temperature is \(temp)°C."))
                deduction += 8
            }
        }

        if let warning = reading.driveWarning {
            issues.append(.init(id: "ata.drivedb-warning", severity: .advisory,
                                title: "Known issue for this drive model",
                                detail: warning))
        }

        return report(deduction: deduction, ratingCap: ratingCap, issues: issues,
                      lifetimeLeft: lifetimeLeft, capturedAt: reading.capturedAt)
    }

    // MARK: - Shared

    private static func report(deduction: Int, ratingCap: HealthRating,
                               issues: [HealthIssue], lifetimeLeft: Int?,
                               capturedAt: Date) -> HealthReport {
        let score = max(0, 100 - deduction)
        let band: HealthRating
        switch score {
        case 90...: band = .good
        case 70...: band = .ok
        case 50...: band = .warning
        case 25...: band = .failing
        default: band = .failed
        }
        var rating = HealthRating.worst(band, ratingCap)
        // A drive with warning-level findings should never be rated GOOD.
        if issues.contains(where: { $0.severity >= .warning }) {
            rating = HealthRating.worst(rating, .warning)
        }
        return HealthReport(
            score: score,
            rating: rating,
            lifetimeLeftPercent: lifetimeLeft,
            issues: issues.sorted { $0.severity > $1.severity },
            capturedAt: capturedAt
        )
    }
}
