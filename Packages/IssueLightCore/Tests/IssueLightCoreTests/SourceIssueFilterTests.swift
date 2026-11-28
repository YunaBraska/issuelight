import Foundation
import XCTest
@testable import IssueLightCore

final class SourceIssueFilterTests: XCTestCase {
    func testLegacyRulesAndCoverageSettingsStillDecode() throws {
        let data = Data(#"{"hideHostsInDowntime":true,"hideAcknowledgedHosts":false,"hideServicesInDowntime":false,"hideAcknowledgedServices":true,"patterns":[{"host":"edge-*","service":""}]}"#.utf8)
        let filter = try JSONDecoder().decode(SourceIssueFilter.self, from: data)
        XCTAssertEqual(filter.hostConditions, [.downtime])
        XCTAssertEqual(filter.serviceConditions, [.acknowledged])
        XCTAssertFalse(filter.showPendingChecks)
        XCTAssertTrue(filter.excludes(issue(kind: .service)))
        XCTAssertEqual(try JSONDecoder().decode(SourceIssueFilter.self, from: JSONEncoder().encode(filter)), filter)
    }

    func testPatternSyntaxAndStatusAreIndependent() {
        var filter = SourceIssueFilter()
        filter.patterns = [.init(host: "^edge-[0-9]+$", service: "^disk-", states: [.critical], usesRegularExpressions: true)]
        XCTAssertTrue(filter.excludes(issue(kind: .service)))
        XCTAssertFalse(filter.excludes(issue(kind: .service, severity: .warning)))
        XCTAssertFalse(filter.excludes(issue(kind: .host)))
        XCTAssertFalse(filter.excludes(issue(kind: .service, host: "core-1")))
        filter.patterns = [.init(host: "[", usesRegularExpressions: true)]
        XCTAssertFalse(filter.patterns[0].hasValidSyntax)
        XCTAssertFalse(filter.excludes(issue(kind: .service, host: "[")))
        filter.patterns = [.init(host: "*", states: [.pending])]
        XCTAssertTrue(filter.excludes(issue(kind: .service, severity: .pending)))
        XCTAssertFalse(filter.excludes(issue(kind: .service)))
        filter.patterns = [.init(host: "*", states: [])]
        XCTAssertFalse(filter.excludes(issue(kind: .service)))
        filter.patterns = [.init(host: "*", states: [.down])]
        XCTAssertTrue(filter.excludes(issue(kind: .host)))
        XCTAssertFalse(filter.excludes(issue(kind: .host, severity: .unknown)))
        XCTAssertFalse(filter.excludes(issue(kind: .service)))
        filter.patterns = [.init(host: "*", states: [.unreachable])]
        XCTAssertTrue(filter.excludes(issue(kind: .host, severity: .unknown)))
        XCTAssertFalse(filter.excludes(issue(kind: .service, severity: .unknown)))
    }

    func testUnknownMetadataPreservesIssuesAndHostDowntimeAppliesOnlyToServices() {
        let service = issue(kind: .service, activity: .init(hostIsInDowntime: true))
        var filter = SourceIssueFilter()
        filter.hideServicesOfHostsInDowntime = true
        XCTAssertTrue(filter.excludes(service))
        XCTAssertFalse(filter.excludes(issue(kind: .host, downtime: true)))
        XCTAssertFalse(filter.excludes(issue(kind: .service, downtime: true)))

        filter = SourceIssueFilter()
        for condition in [IssueFilterCondition.flapping, .notificationsDisabled, .softState] {
            filter.hostConditions = [condition]
            filter.serviceConditions = []
            let matchingActivity = MonitoringIssueActivity(isFlapping: true, notificationsEnabled: false, isSoftState: true)
            XCTAssertTrue(filter.excludes(issue(kind: .host, activity: matchingActivity)))
            XCTAssertFalse(filter.excludes(issue(kind: .service, activity: matchingActivity)))
            XCTAssertFalse(filter.excludes(issue(kind: .host)))
            filter.hostConditions = []
            filter.serviceConditions = [condition]
            XCTAssertTrue(filter.excludes(issue(kind: .service, activity: matchingActivity)))
            XCTAssertFalse(filter.excludes(issue(kind: .service, activity: .init(isFlapping: false, notificationsEnabled: true, isSoftState: false))))
        }
    }

    func testHostAndServiceCoverageRulesAreIndependent() {
        for kind in [MonitoringObjectKind.host, .service] {
            for acknowledged in [false, true] {
                for downtime in [false, true] {
                    let issue = issue(kind: kind, acknowledged: acknowledged, downtime: downtime)
                    var filter = SourceIssueFilter()
                    XCTAssertFalse(filter.excludes(issue))

                    filter.hostConditions.insert(.acknowledged)
                    filter.serviceConditions.insert(.downtime)
                    XCTAssertEqual(filter.excludes(issue), kind == .host ? acknowledged : downtime)

                    filter = SourceIssueFilter()
                    filter.hostConditions.insert(.downtime)
                    filter.serviceConditions.insert(.acknowledged)
                    XCTAssertEqual(filter.excludes(issue), kind == .host ? downtime : acknowledged)
                }
            }
        }
    }

    func testHostOnlyAndServiceOnlyRulesMatchTheEntireNativeName() {
        let host = issue(kind: .host)
        let service = issue(kind: .service)
        var filter = SourceIssueFilter()
        filter.patterns = [.init(host: "edge-?")]
        XCTAssertTrue(filter.excludes(host))
        XCTAssertTrue(filter.excludes(service))
        XCTAssertFalse(filter.excludes(issue(kind: .service, host: "backup-edge-1")))

        filter.patterns = [.init(service: "disk-*")]
        XCTAssertFalse(filter.excludes(host))
        XCTAssertTrue(filter.excludes(service))
        XCTAssertFalse(filter.excludes(issue(kind: .service, service: "Disk-main")))

        filter.patterns = [.init(service: #"disk-\*"#)]
        XCTAssertFalse(filter.excludes(service))
        XCTAssertTrue(filter.excludes(issue(kind: .service, service: "disk-*")))
    }

    func testBothColumnsMustMatchAndAnyNonemptyRuleCanExcludeAnIssue() throws {
        var filter = SourceIssueFilter()
        filter.patterns = [
            .init(host: " edge-* ", service: "disk-?ain"),
            .init(service: "backup"),
            .init(host: " "),
            .init(host: "edge\0*")
        ]
        let saved = try XCTUnwrap(filter.normalized)
        XCTAssertEqual(saved.patterns.count, 2)
        XCTAssertTrue(saved.excludes(issue(kind: .service)))
        XCTAssertFalse(saved.excludes(issue(kind: .host)))
        XCTAssertFalse(saved.excludes(issue(kind: .service, host: "core-1")))
        XCTAssertFalse(saved.excludes(issue(kind: .service, service: "memory")))
        XCTAssertTrue(saved.excludes(issue(kind: .service, host: "core-1", service: "backup")))
        filter.patterns = [.init(host: " ", service: "\n")]
        XCTAssertNil(filter.normalized)
    }

    func testSingleCharacterWildcardSupportsNonASCIIServiceNames() {
        var filter = SourceIssueFilter()
        filter.patterns = [.init(service: "disk-?")]
        XCTAssertTrue(filter.excludes(issue(kind: .service, service: "disk-ä")))
        XCTAssertFalse(filter.excludes(issue(kind: .service, service: "disk-ää")))
    }

    private func issue(
        kind: MonitoringObjectKind,
        host: String = "edge-1",
        service: String = "disk-main",
        acknowledged: Bool = false,
        downtime: Bool = false,
        severity: MonitoringSeverity = .critical,
        activity: MonitoringIssueActivity = .init()
    ) -> MonitoringIssue {
        MonitoringIssue(
            sourceID: UUID(),
            nativeID: "fixture",
            kind: kind,
            hostName: host,
            serviceName: kind == .service ? service : nil,
            displayName: "Display alias",
            severity: severity,
            summary: "Fixture",
            isAcknowledged: acknowledged,
            isInDowntime: downtime,
            activity: activity
        )
    }
}

func assertSourceRulesForIssue(
    _ issue: MonitoringIssue,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    var filter = SourceIssueFilter()
    XCTAssertFalse(filter.excludes(issue), file: file, line: line)

    filter.hostConditions.insert(.downtime)
    filter.hostConditions.insert(.acknowledged)
    XCTAssertEqual(
        filter.excludes(issue),
        issue.kind == .host && (issue.isInDowntime || issue.isAcknowledged),
        file: file, line: line
    )
    filter.serviceConditions.insert(.downtime)
    filter.serviceConditions.insert(.acknowledged)
    XCTAssertEqual(filter.excludes(issue), !issue.requiresAttention, file: file, line: line)

    filter = SourceIssueFilter()
    filter.patterns = [.init(host: "*", service: issue.serviceName ?? "no-service")]
    XCTAssertEqual(filter.excludes(issue), issue.kind == .service, file: file, line: line)
    filter.patterns = [.init(host: "nonexistent-*", service: issue.serviceName ?? "no-service")]
    XCTAssertFalse(filter.excludes(issue), file: file, line: line)
    filter.patterns = [.init(host: "*")]
    XCTAssertTrue(filter.excludes(issue), file: file, line: line)
}

func assertPendingChecksFromLiveProvider(
    _ provider: any MonitoringProvider,
    source: MonitoringSource,
    access: ProviderAccess,
    initialSnapshot: MonitoringSnapshot,
    host: String,
    service: String?,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws -> MonitoringIssue {
    XCTAssertFalse(initialSnapshot.issues.contains { $0.severity == .pending }, file: file, line: line)
    var source = source
    var filter = SourceIssueFilter()
    filter.showPendingChecks = true
    source.issueFilter = filter
    let result = await provider.loadSnapshot(from: source, access: access)
    guard case .loaded(let snapshot) = result else {
        return try XCTUnwrap(nil as MonitoringIssue?, "Expected pending checks from the live provider: \(result)", file: file, line: line)
    }
    let issue = try XCTUnwrap(snapshot.issues.first {
        $0.hostName == host && $0.serviceName == service && $0.severity == .pending
    }, file: file, line: line)
    let ordinaryIssues = snapshot.issues.filter { $0.severity != .pending }
    XCTAssertEqual(Set(ordinaryIssues.map(\.id)), Set(initialSnapshot.issues.map(\.id)), file: file, line: line)
    filter.patterns = [.init(host: host, service: service ?? "", states: [.pending])]
    XCTAssertTrue(filter.excludes(issue), file: file, line: line)
    XCTAssertTrue(ordinaryIssues.allSatisfy { !filter.excludes($0) }, file: file, line: line)
    return issue
}
