import Foundation

public enum MonitoringObjectKind: String, Codable, Sendable {
    case host
    case service
}

public enum MonitoringSeverity: Int, Codable, Comparable, Sendable {
    case pending = 0
    case warning = 1
    case unknown = 2
    case critical = 3

    public static func < (lhs: MonitoringSeverity, rhs: MonitoringSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct MonitoringIssueActivity: Equatable, Sendable {
    public let isFlapping: Bool?
    public let notificationsEnabled: Bool?
    public let isSoftState: Bool?
    public let hostIsInDowntime: Bool?

    public init(
        isFlapping: Bool? = nil,
        notificationsEnabled: Bool? = nil,
        isSoftState: Bool? = nil,
        hostIsInDowntime: Bool? = nil
    ) {
        self.isFlapping = isFlapping
        self.notificationsEnabled = notificationsEnabled
        self.isSoftState = isSoftState
        self.hostIsInDowntime = hostIsInDowntime
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
    public let stateChangedAt: Date?
    public let checkAttempt: Int?
    public let maxCheckAttempts: Int?
    public let isAcknowledged: Bool
    public let isInDowntime: Bool
    public let activity: MonitoringIssueActivity

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
        stateChangedAt: Date? = nil,
        checkAttempt: Int? = nil,
        maxCheckAttempts: Int? = nil,
        isAcknowledged: Bool,
        isInDowntime: Bool,
        activity: MonitoringIssueActivity = .init()
    ) {
        self.sourceID = sourceID
        self.nativeID = nativeID
        self.kind = kind
        self.hostName = hostName
        self.serviceName = serviceName
        self.displayName = displayName
        self.severity = severity
        self.summary = summary
        self.stateChangedAt = stateChangedAt
        self.checkAttempt = checkAttempt
        self.maxCheckAttempts = maxCheckAttempts
        self.isAcknowledged = isAcknowledged
        self.isInDowntime = isInDowntime
        self.activity = activity
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
        serviceData: Data,
        includePending: Bool = false
    ) throws -> MonitoringSnapshot {
        let decoder = JSONDecoder()
        let hosts = try decoder.decode(IcingaEnvelope.self, from: hostData).results
        let services = try decoder.decode(IcingaEnvelope.self, from: serviceData).results

        let hostIssues = try hosts.compactMap { result -> MonitoringIssue? in
            guard result.type == "Host" else {
                throw Icinga2SnapshotDecodingError.invalidObjectType(result.type)
            }
            guard let severity = try result.severity(includePending: includePending) else { return nil }
            return MonitoringIssue(
                sourceID: sourceID,
                nativeID: result.name,
                kind: .host,
                hostName: result.attrs.name,
                serviceName: nil,
                displayName: result.attrs.displayName,
                severity: severity,
                summary: summary(from: result.attrs.lastCheckResult?.output, fallback: result.attrs.displayName),
                stateChangedAt: date(from: result.attrs.lastStateChange),
                checkAttempt: positiveInteger(from: result.attrs.checkAttempt),
                maxCheckAttempts: positiveInteger(from: result.attrs.maxCheckAttempts),
                isAcknowledged: result.attrs.acknowledgement > 0,
                isInDowntime: result.attrs.downtimeDepth > 0,
                activity: result.activity
            )
        }

        let serviceIssues = try services.compactMap { result -> MonitoringIssue? in
            guard result.type == "Service" else {
                throw Icinga2SnapshotDecodingError.invalidObjectType(result.type)
            }
            guard let severity = try result.severity(includePending: includePending) else { return nil }
            guard let hostName = result.attrs.hostName, !hostName.isEmpty else {
                throw Icinga2SnapshotDecodingError.missingHostName(result.name)
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
                stateChangedAt: date(from: result.attrs.lastStateChange),
                checkAttempt: positiveInteger(from: result.attrs.checkAttempt),
                maxCheckAttempts: positiveInteger(from: result.attrs.maxCheckAttempts),
                isAcknowledged: result.attrs.acknowledgement > 0,
                isInDowntime: result.attrs.downtimeDepth > 0,
                activity: result.activity
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
            let displayNameOrder = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            if displayNameOrder != .orderedSame {
                return displayNameOrder == .orderedAscending
            }
            return lhs.nativeID < rhs.nativeID
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

    private func date(from timestamp: Double?) -> Date? {
        guard let timestamp, timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    private func positiveInteger(from value: Double?) -> Int? {
        guard let value, value > 0 else { return nil }
        return Int(value)
    }
}

private struct IcingaEnvelope: Decodable {
    let results: [IcingaResult]
}

private struct IcingaResult: Decodable {
    let attrs: IcingaAttributes
    let joins: Joins?
    let name: String
    let type: String

    func severity(includePending: Bool) throws -> MonitoringSeverity? {
        // Unchecked services can report UNKNOWN until their first check completes.
        if attrs.hasNotRun { return includePending ? .pending : nil }
        let state = Int(attrs.state)
        switch (type, state) {
        case (_, 0): return nil
        case ("Host", 1): return attrs.lastReachable == false ? .unknown : .critical
        case ("Service", 1): return .warning
        case ("Service", 2): return .critical
        case ("Service", 3): return .unknown
        default: throw Icinga2SnapshotDecodingError.unsupportedState(state)
        }
    }

    var activity: MonitoringIssueActivity {
        MonitoringIssueActivity(
            isFlapping: attrs.flapping,
            notificationsEnabled: attrs.enableNotifications,
            isSoftState: attrs.stateType.map { $0 == 0 },
            hostIsInDowntime: joins?.host?.downtimeDepth.map { $0 > 0 }
        )
    }

    struct Joins: Decodable {
        let host: Host?

        struct Host: Decodable {
            let downtimeDepth: Double?

            enum CodingKeys: String, CodingKey {
                case downtimeDepth = "downtime_depth"
            }
        }
    }
}

private struct IcingaAttributes: Decodable {
    let acknowledgement: Double
    let checkAttempt: Double?
    let displayName: String
    let downtimeDepth: Double
    let enableNotifications: Bool?
    let flapping: Bool?
    let hostName: String?
    let lastCheck: Double?
    let lastCheckResult: IcingaCheckResult?
    let lastReachable: Bool?
    let lastStateChange: Double?
    let maxCheckAttempts: Double?
    let name: String
    let state: Double
    let stateType: Double?

    var hasNotRun: Bool {
        lastCheck.map { $0 <= 0 } == true
    }

    private enum CodingKeys: String, CodingKey {
        case acknowledgement
        case checkAttempt = "check_attempt"
        case displayName = "display_name"
        case downtimeDepth = "downtime_depth"
        case enableNotifications = "enable_notifications"
        case flapping
        case hostName = "host_name"
        case lastCheck = "last_check"
        case lastCheckResult = "last_check_result"
        case lastReachable = "last_reachable"
        case lastStateChange = "last_state_change"
        case maxCheckAttempts = "max_check_attempts"
        case name
        case state
        case stateType = "state_type"
    }
}

private struct IcingaCheckResult: Decodable {
    let output: String?
}
