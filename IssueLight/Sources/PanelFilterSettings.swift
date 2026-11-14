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

    private let defaults: UserDefaults
    private let sourceKey = "panel.filter.source"
    private let severityKey = "panel.filter.severity"
    private let coverageKey = "panel.filter.coverage"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sourceID = defaults.string(forKey: sourceKey) ?? ""
        severity = defaults.string(forKey: severityKey).flatMap(PanelSeverityFilter.init(rawValue:)) ?? .all
        coverage = defaults.string(forKey: coverageKey).flatMap(PanelCoverageFilter.init(rawValue:)) ?? .all
    }

    var isActive: Bool {
        !sourceID.isEmpty || severity != .all || coverage != .all
    }

    func includes(_ issue: MonitoringIssue, isCovered: Bool) -> Bool {
        if !sourceID.isEmpty, issue.sourceID.uuidString.lowercased() != sourceID {
            return false
        }
        if !severity.includes(issue) {
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

    func reconcile(sourceIDs: Set<UUID>, isAuthoritative: Bool = true) {
        guard isAuthoritative else { return }
        guard !sourceID.isEmpty else { return }
        if !sourceIDs.map({ $0.uuidString.lowercased() }).contains(sourceID) {
            sourceID = ""
        }
    }

    func reset() {
        sourceID = ""
        severity = .all
        coverage = .all
    }
}
