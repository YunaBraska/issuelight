import Foundation

enum CheckmkSnapshotDecodingError: Error, Equatable {
    case missingHostName
    case missingServiceDescription
    case unsupportedHostState(Int)
    case unsupportedServiceState(Int)
}

struct CheckmkSnapshotDecoder {
    func decode(
        sourceID: UUID,
        observedAt: Date,
        hostData: Data,
        serviceData: Data
    ) throws -> MonitoringSnapshot {
        let decoder = JSONDecoder()
        let hosts = try decoder.decode(CheckmkCollection.self, from: hostData).value
        let services = try decoder.decode(CheckmkCollection.self, from: serviceData).value
        let hostIssues = try hosts.compactMap { try hostIssue($0, sourceID: sourceID) }
        let serviceIssues = try services.compactMap { try serviceIssue($0, sourceID: sourceID) }
        let issues = (hostIssues + serviceIssues).sorted(by: issueOrder)
        return MonitoringSnapshot(sourceID: sourceID, observedAt: observedAt, issues: issues)
    }

    func hostIssue(_ object: CheckmkObject, sourceID: UUID) throws -> MonitoringIssue? {
        guard let state = object.extensions.state else {
            throw CheckmkSnapshotDecodingError.unsupportedHostState(-1)
        }
        guard state != 0 else { return nil }
        let severity: MonitoringSeverity
        switch state {
        case 1:
            severity = .critical
        case 2, 3:
            severity = .unknown
        default:
            throw CheckmkSnapshotDecodingError.unsupportedHostState(state)
        }
        guard let hostName = object.extensions.name?.nonEmpty else {
            throw CheckmkSnapshotDecodingError.missingHostName
        }
        return issue(
            object.extensions,
            sourceID: sourceID,
            kind: .host,
            hostName: hostName,
            serviceName: nil,
            displayName: object.extensions.alias?.nonEmpty ?? hostName,
            severity: severity
        )
    }

    func serviceIssue(_ object: CheckmkObject, sourceID: UUID) throws -> MonitoringIssue? {
        guard let state = object.extensions.state else {
            throw CheckmkSnapshotDecodingError.unsupportedServiceState(-1)
        }
        guard state != 0 else { return nil }
        let severity: MonitoringSeverity
        switch state {
        case 1:
            severity = .warning
        case 2:
            severity = .critical
        case 3:
            severity = .unknown
        default:
            throw CheckmkSnapshotDecodingError.unsupportedServiceState(state)
        }
        guard let hostName = object.extensions.hostName?.nonEmpty else {
            throw CheckmkSnapshotDecodingError.missingHostName
        }
        guard let serviceName = object.extensions.description?.nonEmpty else {
            throw CheckmkSnapshotDecodingError.missingServiceDescription
        }
        return issue(
            object.extensions,
            sourceID: sourceID,
            kind: .service,
            hostName: hostName,
            serviceName: serviceName,
            displayName: serviceName,
            severity: severity
        )
    }

    func issue(
        _ details: CheckmkExtensions,
        sourceID: UUID,
        kind: MonitoringObjectKind,
        hostName: String,
        serviceName: String?,
        displayName: String,
        severity: MonitoringSeverity
    ) -> MonitoringIssue {
        MonitoringIssue(
            sourceID: sourceID,
            nativeID: CheckmkObjectIdentifier.encode(hostName: hostName, serviceName: serviceName),
            kind: kind,
            hostName: hostName,
            serviceName: serviceName,
            displayName: displayName,
            severity: severity,
            summary: details.pluginOutput?.firstOutputLine ?? displayName,
            stateChangedAt: details.lastStateChange.flatMap {
                $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil
            },
            checkAttempt: details.currentAttempt.flatMap { $0 > 0 ? $0 : nil },
            maxCheckAttempts: details.maxCheckAttempts.flatMap { $0 > 0 ? $0 : nil },
            isAcknowledged: (details.acknowledged ?? 0) > 0,
            isInDowntime: (details.scheduledDowntimeDepth ?? 0) > 0
        )
    }

    func issueOrder(_ lhs: MonitoringIssue, _ rhs: MonitoringIssue) -> Bool {
        if lhs.requiresAttention != rhs.requiresAttention { return lhs.requiresAttention }
        if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
        if lhs.kind != rhs.kind { return lhs.kind == .host }
        let hostOrder = lhs.hostName.localizedCaseInsensitiveCompare(rhs.hostName)
        if hostOrder != .orderedSame { return hostOrder == .orderedAscending }
        return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
    }
}

struct CheckmkObjectIdentifier {
    private static let prefix = "checkmk-v1"

    static func encode(hostName: String, serviceName: String?) -> String {
        [prefix, hostName, serviceName ?? ""]
            .map { Data($0.utf8).base64EncodedString() }
            .joined(separator: "|")
    }
}

struct CheckmkCollection: Decodable {
    let value: [CheckmkObject]
}

struct CheckmkObject: Decodable {
    let extensions: CheckmkExtensions
}

struct CheckmkExtensions: Decodable {
    let acknowledged: Int?
    let alias: String?
    let currentAttempt: Int?
    let description: String?
    let hostName: String?
    let lastStateChange: Int?
    let maxCheckAttempts: Int?
    let name: String?
    let pluginOutput: String?
    let scheduledDowntimeDepth: Int?
    let state: Int?

    enum CodingKeys: String, CodingKey {
        case acknowledged
        case alias
        case currentAttempt = "current_attempt"
        case description
        case hostName = "host_name"
        case lastStateChange = "last_state_change"
        case maxCheckAttempts = "max_check_attempts"
        case name
        case pluginOutput = "plugin_output"
        case scheduledDowntimeDepth = "scheduled_downtime_depth"
        case state
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }

    var firstOutputLine: String {
        split(whereSeparator: \.isNewline).first.map(String.init) ?? self
    }
}
