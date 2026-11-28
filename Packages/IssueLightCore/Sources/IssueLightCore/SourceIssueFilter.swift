import Foundation

public struct IssueExclusionPattern: Codable, Equatable, Sendable {
    public var host: String
    public var service: String

    public init(host: String = "", service: String = "") {
        self.host = host
        self.service = service
    }

    fileprivate var trimmed: Self {
        Self(
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            service: service.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    fileprivate func matches(_ issue: MonitoringIssue) -> Bool {
        guard !host.isEmpty || !service.isEmpty else { return false }
        guard host.isEmpty || Self.matches(host, name: issue.hostName) else { return false }
        if service.isEmpty { return true }
        guard issue.kind == .service, let name = issue.serviceName else { return false }
        return Self.matches(service, name: name)
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
    public var hideHostsInDowntime = false
    public var hideAcknowledgedHosts = false
    public var hideServicesInDowntime = false
    public var hideAcknowledgedServices = false
    public var patterns: [IssueExclusionPattern] = []

    public init() {}

    public var normalized: Self? {
        var filter = self
        filter.patterns = patterns.map(\.trimmed).filter {
            (!$0.host.isEmpty || !$0.service.isEmpty)
                && !$0.host.contains("\0") && !$0.service.contains("\0")
        }
        return filter == Self() ? nil : filter
    }

    public func excludes(_ issue: MonitoringIssue) -> Bool {
        switch issue.kind {
        case .host:
            if (hideHostsInDowntime && issue.isInDowntime)
                || (hideAcknowledgedHosts && issue.isAcknowledged) { return true }
        case .service:
            if (hideServicesInDowntime && issue.isInDowntime)
                || (hideAcknowledgedServices && issue.isAcknowledged) { return true }
        }
        return patterns.contains { $0.matches(issue) }
    }
}
