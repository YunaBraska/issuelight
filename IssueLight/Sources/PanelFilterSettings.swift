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
    @Published private(set) var hostSelections: Set<PanelHostSelection> {
        didSet {
            if hostSelections.isEmpty {
                defaults.removeObject(forKey: hostsKey)
            } else if let data = try? JSONEncoder().encode(hostSelections) {
                defaults.set(data, forKey: hostsKey)
            }
        }
    }

    private let defaults: UserDefaults
    private let sourceKey = "panel.filter.source"
    private let severityKey = "panel.filter.severity"
    private let coverageKey = "panel.filter.coverage"
    private let hostsKey = "panel.filter.hosts"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sourceID = defaults.string(forKey: sourceKey) ?? ""
        severity = defaults.string(forKey: severityKey).flatMap(PanelSeverityFilter.init(rawValue:)) ?? .all
        coverage = defaults.string(forKey: coverageKey).flatMap(PanelCoverageFilter.init(rawValue:)) ?? .all
        hostSelections = defaults.data(forKey: hostsKey)
            .flatMap { try? JSONDecoder().decode(Set<PanelHostSelection>.self, from: $0) }
            ?? []
    }

    var isActive: Bool {
        !sourceID.isEmpty || severity != .all || coverage != .all || !hostSelections.isEmpty
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
        hostSelections.isEmpty || hostSelections.contains(PanelHostSelection(issue: issue))
    }

    func isHostSelected(_ selection: PanelHostSelection) -> Bool {
        hostSelections.contains(selection)
    }

    func setHost(_ selection: PanelHostSelection, selected: Bool) {
        if selected {
            hostSelections.insert(selection)
        } else {
            hostSelections.remove(selection)
        }
    }

    func clearHosts() {
        hostSelections = []
    }

    func reconcile(sourceIDs: Set<UUID>, isAuthoritative: Bool = true) {
        guard isAuthoritative else { return }
        let storedSourceIDs = Set(sourceIDs.map { $0.uuidString.lowercased() })
        if !sourceID.isEmpty, !storedSourceIDs.contains(sourceID) {
            sourceID = ""
        }
        let retainedHosts = Set(hostSelections.filter { sourceIDs.contains($0.sourceID) })
        if retainedHosts != hostSelections {
            hostSelections = retainedHosts
        }
    }

    func reset() {
        sourceID = ""
        severity = .all
        coverage = .all
        hostSelections = []
    }
}
