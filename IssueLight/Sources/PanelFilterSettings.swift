import Foundation
import IssueLightCore

enum PanelSeverityFilter: String, CaseIterable, Identifiable {
    case all
    case critical
    case warning
    case unknown
    case down

    var id: String { rawValue }

    func includes(_ issue: MonitoringIssue) -> Bool {
        switch self {
        case .all:
            return true
        case .critical:
            return issue.kind == .service && issue.severity == .critical
        case .warning:
            return issue.kind == .service && issue.severity == .warning
        case .unknown:
            return issue.kind == .service && issue.severity == .unknown
        case .down:
            return issue.kind == .host
        }
    }
}

enum PanelCoverageFilter: String, CaseIterable, Identifiable {
    case all
    case attention
    case covered

    var id: String { rawValue }
}

struct PanelHostSelection: Codable, Hashable, Identifiable {
    let sourceID: UUID
    let hostName: String

    var id: String {
        "\(sourceID.uuidString.lowercased()):\(hostName)"
    }

    init(sourceID: UUID, hostName: String) {
        self.sourceID = sourceID
        self.hostName = hostName
    }

    init(issue: MonitoringIssue) {
        sourceID = issue.sourceID
        hostName = issue.hostName
    }
}

@MainActor
final class PanelFilterSettings: ObservableObject {
    @Published var sourceID: String {
        didSet { defaults.set(sourceID, forKey: sourceKey) }
    }
    @Published var severity: PanelSeverityFilter {
        didSet { defaults.set(severity.rawValue, forKey: severityKey) }
    }
    @Published var coverage: PanelCoverageFilter {
        didSet { defaults.set(coverage.rawValue, forKey: coverageKey) }
    }
    @Published private(set) var excludedHosts: Set<PanelHostSelection> {
        didSet {
            if excludedHosts.isEmpty {
                defaults.removeObject(forKey: excludedHostsKey)
            } else if let data = try? JSONEncoder().encode(excludedHosts) {
                defaults.set(data, forKey: excludedHostsKey)
            }
        }
    }

    private let defaults: UserDefaults
    private let sourceKey = "panel.filter.source"
    private let severityKey = "panel.filter.severity"
    private let coverageKey = "panel.filter.coverage"
    private let excludedHostsKey = "panel.filter.excluded-hosts"
    private let legacyIncludedHostsKey = "panel.filter.hosts"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sourceID = defaults.string(forKey: sourceKey) ?? ""
        severity = defaults.string(forKey: severityKey).flatMap(PanelSeverityFilter.init(rawValue:)) ?? .all
        coverage = defaults.string(forKey: coverageKey).flatMap(PanelCoverageFilter.init(rawValue:)) ?? .all
        excludedHosts = defaults.data(forKey: excludedHostsKey)
            .flatMap { try? JSONDecoder().decode(Set<PanelHostSelection>.self, from: $0) }
            ?? []
        defaults.removeObject(forKey: legacyIncludedHostsKey)
    }

    var isActive: Bool {
        !sourceID.isEmpty || severity != .all || coverage != .all || !excludedHosts.isEmpty
    }

    func includes(_ issue: MonitoringIssue, isCovered: Bool) -> Bool {
        if !sourceID.isEmpty, issue.sourceID.uuidString.lowercased() != sourceID {
            return false
        }
        if !severity.includes(issue) {
            return false
        }
        if !includesHost(issue) {
            return false
        }
        switch coverage {
        case .all:
            return true
        case .attention:
            return !isCovered
        case .covered:
            return isCovered
        }
    }

    func includesHost(_ issue: MonitoringIssue) -> Bool {
        !excludedHosts.contains(PanelHostSelection(issue: issue))
    }

    func isHostExcluded(_ selection: PanelHostSelection) -> Bool {
        excludedHosts.contains(selection)
    }

    func setHost(_ selection: PanelHostSelection, excluded: Bool) {
        if excluded {
            excludedHosts.insert(selection)
        } else {
            excludedHosts.remove(selection)
        }
    }

    func showAllHosts() {
        excludedHosts = []
    }

    func reconcile(sourceIDs: Set<UUID>, isAuthoritative: Bool = true) {
        guard isAuthoritative else { return }
        let storedSourceIDs = Set(sourceIDs.map { $0.uuidString.lowercased() })
        if !sourceID.isEmpty, !storedSourceIDs.contains(sourceID) {
            sourceID = ""
        }
        let retainedHosts = Set(excludedHosts.filter { sourceIDs.contains($0.sourceID) })
        if retainedHosts != excludedHosts {
            excludedHosts = retainedHosts
        }
    }

    func reset() {
        sourceID = ""
        severity = .all
        coverage = .all
        excludedHosts = []
    }
}
