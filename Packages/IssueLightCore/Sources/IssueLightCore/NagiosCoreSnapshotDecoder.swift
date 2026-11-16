import Foundation

enum NagiosCoreSnapshotDecodingError: Error, Equatable {
    case failedResult(Int)
    case missingHostName
    case missingServiceDescription
    case unsupportedHostState(Int)
    case unsupportedServiceState(Int)
}

struct NagiosCoreSnapshotDecoder {
    func decode(
        sourceID: UUID,
        observedAt: Date,
        hostData: Data,
        serviceData: Data
    ) throws -> MonitoringSnapshot {
        let decoder = JSONDecoder()
        let hostEnvelope = try decoder.decode(NagiosHostEnvelope.self, from: hostData)
        let serviceEnvelope = try decoder.decode(NagiosServiceEnvelope.self, from: serviceData)
        guard hostEnvelope.result.typeCode == 0 else {
            throw NagiosCoreSnapshotDecodingError.failedResult(hostEnvelope.result.typeCode)
        }
        guard serviceEnvelope.result.typeCode == 0 else {
            throw NagiosCoreSnapshotDecodingError.failedResult(serviceEnvelope.result.typeCode)
        }
        let hostIssues = try hostEnvelope.data.hostlist.values.compactMap {
            try hostIssue($0, sourceID: sourceID)
        }
        let serviceIssues = try serviceEnvelope.data.servicelist.values
            .flatMap(\.values)
            .compactMap { try serviceIssue($0, sourceID: sourceID) }
        return MonitoringSnapshot(
            sourceID: sourceID,
            observedAt: observedAt,
            issues: (hostIssues + serviceIssues).sorted(by: issueOrder)
        )
    }

    func hostIssue(_ object: NagiosStatusObject, sourceID: UUID) throws -> MonitoringIssue? {
        guard let status = object.status else {
            throw NagiosCoreSnapshotDecodingError.unsupportedHostState(-1)
        }
        let severity: MonitoringSeverity
        switch status {
        case 1, 2:
            return nil
        case 4:
            severity = .critical
        case 8:
            severity = .unknown
        default:
            throw NagiosCoreSnapshotDecodingError.unsupportedHostState(status)
        }
        guard let hostName = object.name?.nonEmpty else {
            throw NagiosCoreSnapshotDecodingError.missingHostName
        }
        return issue(
            object,
            sourceID: sourceID,
            kind: .host,
            hostName: hostName,
            serviceName: nil,
            displayName: hostName,
            severity: severity
        )
    }

    func serviceIssue(_ object: NagiosStatusObject, sourceID: UUID) throws -> MonitoringIssue? {
        guard let status = object.status else {
            throw NagiosCoreSnapshotDecodingError.unsupportedServiceState(-1)
        }
        let severity: MonitoringSeverity
        switch status {
        case 1, 2:
            return nil
        case 4:
            severity = .warning
        case 8:
            severity = .unknown
        case 16:
            severity = .critical
        default:
            throw NagiosCoreSnapshotDecodingError.unsupportedServiceState(status)
        }
        guard let hostName = object.hostName?.nonEmpty else {
            throw NagiosCoreSnapshotDecodingError.missingHostName
        }
        guard let serviceName = object.description?.nonEmpty else {
            throw NagiosCoreSnapshotDecodingError.missingServiceDescription
        }
        return issue(
            object,
            sourceID: sourceID,
            kind: .service,
            hostName: hostName,
            serviceName: serviceName,
            displayName: serviceName,
            severity: severity
        )
    }

    func issue(
        _ object: NagiosStatusObject,
        sourceID: UUID,
        kind: MonitoringObjectKind,
        hostName: String,
        serviceName: String?,
        displayName: String,
        severity: MonitoringSeverity
    ) -> MonitoringIssue {
        MonitoringIssue(
            sourceID: sourceID,
            nativeID: NagiosCoreObjectIdentifier.encode(
                hostName: hostName,
                serviceName: serviceName
            ),
            kind: kind,
            hostName: hostName,
            serviceName: serviceName,
            displayName: displayName,
            severity: severity,
            summary: object.pluginOutput?.firstOutputLine ?? displayName,
            stateChangedAt: object.lastStateChange.flatMap {
                $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil
            },
            checkAttempt: object.currentAttempt.flatMap { $0 > 0 ? $0 : nil },
            maxCheckAttempts: object.maxAttempts.flatMap { $0 > 0 ? $0 : nil },
            isAcknowledged: object.problemHasBeenAcknowledged ?? false,
            isInDowntime: (object.scheduledDowntimeDepth ?? 0) > 0
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

struct NagiosCoreObjectIdentifier {
    private static let prefix = "nagios-core-v1"

    static func encode(hostName: String, serviceName: String?) -> String {
        [prefix, hostName, serviceName ?? ""]
            .map { Data($0.utf8).base64EncodedString() }
            .joined(separator: "|")
    }
}

struct NagiosResultEnvelope: Decodable {
    let result: NagiosResult
}

struct NagiosHostEnvelope: Decodable {
    let result: NagiosResult
    let data: NagiosHostData
}

struct NagiosServiceEnvelope: Decodable {
    let result: NagiosResult
    let data: NagiosServiceData
}

struct NagiosResult: Decodable {
    let cgi: String
    let query: String?
    let typeCode: Int
    let message: String

    enum CodingKeys: String, CodingKey {
        case cgi
        case query
        case typeCode = "type_code"
        case message
    }
}

struct NagiosHostData: Decodable {
    let hostlist: [String: NagiosStatusObject]
}

struct NagiosServiceData: Decodable {
    let servicelist: [String: [String: NagiosStatusObject]]
}

struct NagiosStatusObject: Decodable {
    let currentAttempt: Int?
    let description: String?
    let hostName: String?
    let lastStateChange: Int?
    let maxAttempts: Int?
    let name: String?
    let pluginOutput: String?
    let problemHasBeenAcknowledged: Bool?
    let scheduledDowntimeDepth: Int?
    let status: Int?

    enum CodingKeys: String, CodingKey {
        case currentAttempt = "current_attempt"
        case description
        case hostName = "host_name"
        case lastStateChange = "last_state_change"
        case maxAttempts = "max_attempts"
        case name
        case pluginOutput = "plugin_output"
        case problemHasBeenAcknowledged = "problem_has_been_acknowledged"
        case scheduledDowntimeDepth = "scheduled_downtime_depth"
        case status
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
