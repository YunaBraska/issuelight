import Foundation

public enum IssueFilterCondition: String, Codable, CaseIterable, Sendable {
    case downtime
    case acknowledged
    case flapping
    case notificationsDisabled
    case softState

    fileprivate func matches(_ issue: MonitoringIssue) -> Bool {
        switch self {
        case .downtime: issue.isInDowntime
        case .acknowledged: issue.isAcknowledged
        case .flapping: issue.activity.isFlapping == true
        case .notificationsDisabled: issue.activity.notificationsEnabled == false
        case .softState: issue.activity.isSoftState == true && issue.severity != .pending
        }
    }
}

public enum IssueFilterState: String, Codable, CaseIterable, Sendable {
    case pending
    case down
    case unreachable
    case critical
    case warning
    case unknown

    public init(_ issue: MonitoringIssue) {
        switch (issue.kind, issue.severity) {
        case (_, .pending): self = .pending
        case (.host, .unknown): self = .unreachable
        case (.host, _): self = .down
        case (.service, .critical): self = .critical
        case (.service, .warning): self = .warning
        case (.service, .unknown): self = .unknown
        }
    }
}

public struct IssueExclusionPattern: Codable, Equatable, Sendable {
    public var host: String
    public var service: String
    public var states: Set<IssueFilterState>?
    public var usesRegularExpressions: Bool?

    public init(
        host: String = "",
        service: String = "",
        states: Set<IssueFilterState>? = nil,
        usesRegularExpressions: Bool? = nil
    ) {
        self.host = host
        self.service = service
        self.states = states
        self.usesRegularExpressions = usesRegularExpressions
    }

    public var hasValidSyntax: Bool {
        trimmed.matcher != nil
    }

    fileprivate var trimmed: Self {
        Self(
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            service: service.trimmingCharacters(in: .whitespacesAndNewlines),
            states: states,
            usesRegularExpressions: usesRegularExpressions == true ? true : nil
        )
    }

    fileprivate var matcher: ((MonitoringIssue) -> Bool)? {
        guard !host.contains("\0"), !service.contains("\0"),
              let matchesHost = nameMatcher(host), let matchesService = nameMatcher(service) else { return nil }
        return { issue in
            guard !host.isEmpty || !service.isEmpty,
                  states?.contains(IssueFilterState(issue)) != false,
                  matchesHost(issue.hostName) else { return false }
            if service.isEmpty { return true }
            return issue.kind == .service && issue.serviceName.map(matchesService) == true
        }
    }

    private func nameMatcher(_ pattern: String) -> ((String) -> Bool)? {
        if pattern.isEmpty { return { _ in true } }
        guard usesRegularExpressions == true else { return { Self.matches(pattern, name: $0) } }
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        return { name in
            expression.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
        }
    }

    private static func matches(_ pattern: String, name: String) -> Bool {
        var patternIndex = pattern.startIndex
        var nameIndex = name.startIndex
        var star: (restOfPattern: String.Index, consumedThrough: String.Index)?

        while nameIndex < name.endIndex {
            if patternIndex < pattern.endIndex {
                let token = pattern[patternIndex]
                var next = pattern.index(after: patternIndex)
                if token == "*" {
                    star = (next, nameIndex)
                    patternIndex = next
                    continue
                }

                var literal = token
                if token == "\\", next < pattern.endIndex {
                    literal = pattern[next]
                    pattern.formIndex(after: &next)
                }
                if token == "?" || literal == name[nameIndex] {
                    name.formIndex(after: &nameIndex)
                    patternIndex = next
                    continue
                }
            }

            // Let the last wildcard consume one more character and retry its suffix.
            guard var retry = star, retry.consumedThrough < name.endIndex else { return false }
            name.formIndex(after: &retry.consumedThrough)
            nameIndex = retry.consumedThrough
            patternIndex = retry.restOfPattern
            star = retry
        }
        return pattern[patternIndex...].allSatisfy { $0 == "*" }
    }
}

public struct SourceIssueFilter: Codable, Equatable, Sendable {
    public var hostConditions: Set<IssueFilterCondition> = []
    public var serviceConditions: Set<IssueFilterCondition> = []
    public var hideServicesOfHostsInDowntime = false
    public var showPendingChecks = false
    public var patterns: [IssueExclusionPattern] = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        hostConditions = try values.decodeIfPresent(Set<IssueFilterCondition>.self, forKey: .hostConditions) ?? []
        serviceConditions = try values.decodeIfPresent(Set<IssueFilterCondition>.self, forKey: .serviceConditions) ?? []
        if try legacy.decodeIfPresent(Bool.self, forKey: .hideHostsInDowntime) == true {
            hostConditions.insert(.downtime)
        }
        if try legacy.decodeIfPresent(Bool.self, forKey: .hideAcknowledgedHosts) == true {
            hostConditions.insert(.acknowledged)
        }
        if try legacy.decodeIfPresent(Bool.self, forKey: .hideServicesInDowntime) == true {
            serviceConditions.insert(.downtime)
        }
        if try legacy.decodeIfPresent(Bool.self, forKey: .hideAcknowledgedServices) == true {
            serviceConditions.insert(.acknowledged)
        }
        hideServicesOfHostsInDowntime = try values.decodeIfPresent(Bool.self, forKey: .hideServicesOfHostsInDowntime) ?? false
        showPendingChecks = try values.decodeIfPresent(Bool.self, forKey: .showPendingChecks) ?? false
        patterns = try values.decodeIfPresent([IssueExclusionPattern].self, forKey: .patterns) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case hostConditions, serviceConditions, hideServicesOfHostsInDowntime, showPendingChecks, patterns
    }

    private enum LegacyKeys: String, CodingKey {
        case hideHostsInDowntime, hideAcknowledgedHosts, hideServicesInDowntime, hideAcknowledgedServices
    }

    public var normalized: Self? {
        var filter = self
        filter.patterns = patterns.map(\.trimmed).filter {
            (!$0.host.isEmpty || !$0.service.isEmpty) && $0.hasValidSyntax
        }
        return filter == Self() ? nil : filter
    }

    public func excludes(_ issue: MonitoringIssue) -> Bool {
        exclusionPredicate(issue)
    }

    public func retainingVisibleIssues(_ issues: [MonitoringIssue]) -> [MonitoringIssue] {
        let excludes = exclusionPredicate
        return issues.filter { !excludes($0) }
    }

    private var exclusionPredicate: (MonitoringIssue) -> Bool {
        let rules = patterns.compactMap(\.matcher)
        return { issue in
            let conditions = issue.kind == .host ? hostConditions : serviceConditions
            return conditions.contains { $0.matches(issue) }
                || (issue.kind == .service && hideServicesOfHostsInDowntime && issue.activity.hostIsInDowntime == true)
                || rules.contains { $0(issue) }
        }
    }
}
