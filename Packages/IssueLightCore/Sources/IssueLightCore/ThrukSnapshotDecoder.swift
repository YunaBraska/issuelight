import Foundation

enum ThrukSnapshotDecodingError: Error, Equatable {
    case missingHostName
    case missingServiceDescription
    case unsupportedHostState(Int)
    case unsupportedServiceState(Int)
}

struct ThrukSnapshotDecoder {
    func decode(
        sourceID: UUID,
        observedAt: Date,
        hostData: Data,
        serviceData: Data
    ) throws -> MonitoringSnapshot {
        let decoder = JSONDecoder()
        let hosts = try decoder.decode([ThrukObject].self, from: hostData)
        let services = try decoder.decode([ThrukObject].self, from: serviceData)
        let hostIssues = try hosts.compactMap { try hostIssue($0, sourceID: sourceID) }
        let serviceIssues = try services.compactMap { try serviceIssue($0, sourceID: sourceID) }
        return MonitoringSnapshot(
            sourceID: sourceID,
            observedAt: observedAt,
            issues: hostIssues + serviceIssues
        )
    }

    func hostIssue(_ object: ThrukObject, sourceID: UUID) throws -> MonitoringIssue? {
        guard let state = object.state?.value else {
            throw ThrukSnapshotDecodingError.unsupportedHostState(-1)
        }
        guard state != 0 else { return nil }
        let severity: MonitoringSeverity
        switch state {
        case 1:
            severity = .critical
        case 2, 3:
            severity = .unknown
        default:
            throw ThrukSnapshotDecodingError.unsupportedHostState(state)
        }
        guard let hostName = object.name?.nonEmpty else {
            throw ThrukSnapshotDecodingError.missingHostName
        }
        return issue(
            object,
            sourceID: sourceID,
            nativeID: ThrukObjectIdentifier.encode(
                backendID: object.peerKey,
                hostName: hostName,
                serviceName: nil
            ),
            kind: .host,
            hostName: hostName,
            serviceName: nil,
            displayName: object.displayName?.nonEmpty ?? hostName,
            severity: severity
        )
    }

    func serviceIssue(_ object: ThrukObject, sourceID: UUID) throws -> MonitoringIssue? {
        guard let state = object.state?.value else {
            throw ThrukSnapshotDecodingError.unsupportedServiceState(-1)
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
            throw ThrukSnapshotDecodingError.unsupportedServiceState(state)
        }
        guard let hostName = object.hostName?.nonEmpty else {
            throw ThrukSnapshotDecodingError.missingHostName
        }
        guard let serviceName = object.description?.nonEmpty else {
            throw ThrukSnapshotDecodingError.missingServiceDescription
        }
        return issue(
            object,
            sourceID: sourceID,
            nativeID: ThrukObjectIdentifier.encode(
                backendID: object.peerKey,
                hostName: hostName,
                serviceName: serviceName
            ),
            kind: .service,
            hostName: hostName,
            serviceName: serviceName,
            displayName: object.displayName?.nonEmpty ?? serviceName,
            severity: severity
        )
    }

    func issue(
        _ object: ThrukObject,
        sourceID: UUID,
        nativeID: String,
        kind: MonitoringObjectKind,
        hostName: String,
        serviceName: String?,
        displayName: String,
        severity: MonitoringSeverity
    ) -> MonitoringIssue {
        MonitoringIssue(
            sourceID: sourceID,
            nativeID: nativeID,
            kind: kind,
            hostName: hostName,
            serviceName: serviceName,
            displayName: displayName,
            severity: severity,
            summary: object.pluginOutput?.firstOutputLine ?? "",
            stateChangedAt: object.lastStateChange.flatMap {
                $0.value > 0 ? Date(timeIntervalSince1970: TimeInterval($0.value)) : nil
            },
            checkAttempt: object.currentAttempt?.value,
            maxCheckAttempts: object.maxCheckAttempts?.value,
            isAcknowledged: object.acknowledged?.value ?? false,
            isInDowntime: (object.scheduledDowntimeDepth?.value ?? 0) > 0
        )
    }

}

struct ThrukObjectIdentifier {
    private static let prefix = "thruk-v1"

    static func encode(backendID: String?, hostName: String, serviceName: String?) -> String {
        [prefix, backendID ?? "", hostName, serviceName ?? ""]
            .map { Data($0.utf8).base64EncodedString() }
            .joined(separator: "|")
    }

    static func backendID(from nativeID: String) -> String? {
        let components = nativeID.split(separator: "|", omittingEmptySubsequences: false)
        guard components.count == 4,
              decode(String(components[0])) == prefix,
              let value = decode(String(components[1])),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func decode(_ value: String) -> String? {
        Data(base64Encoded: value).flatMap { String(data: $0, encoding: .utf8) }
    }
}

struct ThrukObject: Decodable {
    let acknowledged: ThrukBoolean?
    let currentAttempt: ThrukInteger?
    let description: String?
    let displayName: String?
    let hostName: String?
    let lastStateChange: ThrukInteger?
    let maxCheckAttempts: ThrukInteger?
    let name: String?
    let peerKey: String?
    let pluginOutput: String?
    let scheduledDowntimeDepth: ThrukInteger?
    let state: ThrukInteger?

    enum CodingKeys: String, CodingKey {
        case acknowledged
        case currentAttempt = "current_attempt"
        case description
        case displayName = "display_name"
        case hostName = "host_name"
        case lastStateChange = "last_state_change"
        case maxCheckAttempts = "max_check_attempts"
        case name
        case peerKey = "peer_key"
        case pluginOutput = "plugin_output"
        case scheduledDowntimeDepth = "scheduled_downtime_depth"
        case state
    }
}

struct ThrukInteger: Decodable {
    let value: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self.value = value
        } else if let value = try? container.decode(Double.self),
                  let integer = Int(exactly: value) {
            self.value = integer
        } else if let value = try? container.decode(String.self), let integer = Int(value) {
            self.value = integer
        } else {
            throw DecodingError.typeMismatch(
                Int.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected an integer")
            )
        }
    }
}

struct ThrukBoolean: Decodable {
    let value: Bool

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self.value = value
        } else if let value = try? container.decode(Int.self), [0, 1].contains(value) {
            self.value = value == 1
        } else if let value = try? container.decode(String.self) {
            switch value.lowercased() {
            case "1", "true", "yes":
                self.value = true
            case "0", "false", "no":
                self.value = false
            default:
                throw DecodingError.typeMismatch(
                    Bool.self,
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "Expected a boolean"
                    )
                )
            }
        } else {
            throw DecodingError.typeMismatch(
                Bool.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected a boolean")
            )
        }
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
