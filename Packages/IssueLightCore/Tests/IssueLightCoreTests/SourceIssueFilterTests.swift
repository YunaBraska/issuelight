import Foundation
import XCTest
@testable import IssueLightCore

final class SourceIssueFilterTests: XCTestCase {
    func testHostAndServiceCoverageRulesAreIndependent() {
        for kind in [MonitoringObjectKind.host, .service] {
            for acknowledged in [false, true] {
                for downtime in [false, true] {
                    let issue = issue(kind: kind, acknowledged: acknowledged, downtime: downtime)
                    var filter = SourceIssueFilter()
                    XCTAssertFalse(filter.excludes(issue))

                    filter.hideAcknowledgedHosts = true
                    filter.hideServicesInDowntime = true
                    XCTAssertEqual(filter.excludes(issue), kind == .host ? acknowledged : downtime)

                    filter = SourceIssueFilter()
                    filter.hideHostsInDowntime = true
                    filter.hideAcknowledgedServices = true
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
        downtime: Bool = false
    ) -> MonitoringIssue {
        MonitoringIssue(
            sourceID: UUID(),
            nativeID: "fixture",
            kind: kind,
            hostName: host,
            serviceName: kind == .service ? service : nil,
            displayName: "Display alias",
            severity: .critical,
            summary: "Fixture",
            isAcknowledged: acknowledged,
            isInDowntime: downtime
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

    filter.hideHostsInDowntime = true
    filter.hideAcknowledgedHosts = true
    XCTAssertEqual(
        filter.excludes(issue),
        issue.kind == .host && (issue.isInDowntime || issue.isAcknowledged),
        file: file, line: line
    )
    filter.hideServicesInDowntime = true
    filter.hideAcknowledgedServices = true
    XCTAssertEqual(filter.excludes(issue), !issue.requiresAttention, file: file, line: line)

    filter = SourceIssueFilter()
    filter.patterns = [.init(host: "*", service: issue.serviceName ?? "no-service")]
    XCTAssertEqual(filter.excludes(issue), issue.kind == .service, file: file, line: line)
    filter.patterns = [.init(host: "nonexistent-*", service: issue.serviceName ?? "no-service")]
    XCTAssertFalse(filter.excludes(issue), file: file, line: line)
    filter.patterns = [.init(host: "*")]
    XCTAssertTrue(filter.excludes(issue), file: file, line: line)
}
