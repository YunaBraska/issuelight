import Foundation

public enum MonitoringObjectKind: String, Codable, Sendable {
    case host
    case service
}

public enum MonitoringSeverity: Int, Codable, Comparable, Sendable {
    case warning = 1
    case unknown = 2
    case critical = 3

    public static func < (lhs: MonitoringSeverity, rhs: MonitoringSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct MonitoringIssue: Equatable, Identifiable, Sendable {
    public let sourceID: UUID
    public let nativeID: String
    public let kind: MonitoringObjectKind
    public let hostName: String
    public let serviceName: String?
    public let displayName: String
    public let severity: MonitoringSeverity
    public let summary: String
    public let isAcknowledged: Bool
    public let isInDowntime: Bool

    public var id: String {
        "\(sourceID.uuidString.lowercased()):\(kind.rawValue):\(nativeID)"
    }

    public var requiresAttention: Bool {
        !isAcknowledged && !isInDowntime
    }

    public init(
        sourceID: UUID,
        nativeID: String,
        kind: MonitoringObjectKind,
        hostName: String,
        serviceName: String?,
        displayName: String,
        severity: MonitoringSeverity,
        summary: String,
        isAcknowledged: Bool,
        isInDowntime: Bool
    ) {
        self.sourceID = sourceID
        self.nativeID = nativeID
        self.kind = kind
        self.hostName = hostName
        self.serviceName = serviceName
        self.displayName = displayName
        self.severity = severity
        self.summary = summary
        self.isAcknowledged = isAcknowledged
        self.isInDowntime = isInDowntime
    }
}

public struct MonitoringSnapshot: Equatable, Sendable {
    public let sourceID: UUID
    public let observedAt: Date
    public let issues: [MonitoringIssue]

    public var actionableIssues: [MonitoringIssue] {
        issues.filter(\.requiresAttention)
    }

    public var highestAttentionSeverity: MonitoringSeverity? {
        actionableIssues.map(\.severity).max()
    }

    public init(sourceID: UUID, observedAt: Date, issues: [MonitoringIssue]) {
        self.sourceID = sourceID
        self.observedAt = observedAt
        self.issues = issues
    }
}

enum Icinga2SnapshotDecodingError: Error, Equatable {
    case invalidObjectType(String)
    case missingHostName(String)
    case unsupportedState(Int)
}

struct Icinga2SnapshotDecoder {
    func decode(
        sourceID: UUID,
        observedAt: Date,
        hostData: Data,
        serviceData: Data
    ) throws -> MonitoringSnapshot {
        let decoder = JSONDecoder()
        let hosts = try decoder.decode(IcingaEnvelope.self, from: hostData).results
        let services = try decoder.decode(IcingaEnvelope.self, from: serviceData).results

        let hostIssues = try hosts.compactMap { result -> MonitoringIssue? in
            guard result.type == "Host" else {
                throw Icinga2SnapshotDecodingError.invalidObjectType(result.type)
            }
            let state = Int(result.attrs.state)
            guard state != 0 else { return nil }
            guard state == 1 else {
                throw Icinga2SnapshotDecodingError.unsupportedState(state)
            }
            return MonitoringIssue(
                sourceID: sourceID,
                nativeID: result.name,
                kind: .host,
                hostName: result.attrs.name,
                serviceName: nil,
                displayName: result.attrs.displayName,
                severity: .critical,
                summary: summary(from: result.attrs.lastCheckResult?.output, fallback: result.attrs.displayName),
                isAcknowledged: result.attrs.acknowledgement > 0,
                isInDowntime: result.attrs.downtimeDepth > 0
            )
        }

        let serviceIssues = try services.compactMap { result -> MonitoringIssue? in
            guard result.type == "Service" else {
                throw Icinga2SnapshotDecodingError.invalidObjectType(result.type)
            }
            let state = Int(result.attrs.state)
            guard state != 0 else { return nil }
            guard let hostName = result.attrs.hostName, !hostName.isEmpty else {
                throw Icinga2SnapshotDecodingError.missingHostName(result.name)
            }
            let severity: MonitoringSeverity
            switch state {
            case 1:
                severity = .warning
            case 2:
                severity = .critical
            case 3:
                severity = .unknown
            default:
                throw Icinga2SnapshotDecodingError.unsupportedState(state)
            }
            return MonitoringIssue(
                sourceID: sourceID,
                nativeID: result.name,
                kind: .service,
                hostName: hostName,
                serviceName: result.attrs.name,
                displayName: result.attrs.displayName,
                severity: severity,
                summary: summary(from: result.attrs.lastCheckResult?.output, fallback: result.attrs.displayName),
                isAcknowledged: result.attrs.acknowledgement > 0,
                isInDowntime: result.attrs.downtimeDepth > 0
            )
        }

        let issues = (hostIssues + serviceIssues).sorted { lhs, rhs in
            if lhs.requiresAttention != rhs.requiresAttention {
                return lhs.requiresAttention
            }
            if lhs.severity != rhs.severity {
                return lhs.severity > rhs.severity
            }
            if lhs.kind != rhs.kind {
                return lhs.kind == .host
            }
            let hostOrder = lhs.hostName.localizedCaseInsensitiveCompare(rhs.hostName)
            if hostOrder != .orderedSame {
                return hostOrder == .orderedAscending
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }

        return MonitoringSnapshot(sourceID: sourceID, observedAt: observedAt, issues: issues)
    }

    private func summary(from output: String?, fallback: String) -> String {
        let firstLine = output?
            .split(whereSeparator: \Character.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstLine, !firstLine.isEmpty else { return fallback }
        return firstLine
    }
}

private struct IcingaEnvelope: Decodable {
    let results: [IcingaResult]
}

private struct IcingaResult: Decodable {
    let attrs: IcingaAttributes
    let name: String
    let type: String
}

private struct IcingaAttributes: Decodable {
    let acknowledgement: Double
    let displayName: String
    let downtimeDepth: Double
    let hostName: String?
    let lastCheckResult: IcingaCheckResult?
    let name: String
    let state: Double

    private enum CodingKeys: String, CodingKey {
        case acknowledgement
        case displayName = "display_name"
        case downtimeDepth = "downtime_depth"
        case hostName = "host_name"
        case lastCheckResult = "last_check_result"
        case name
        case state
    }
}

private struct IcingaCheckResult: Decodable {
    let output: String?
}
