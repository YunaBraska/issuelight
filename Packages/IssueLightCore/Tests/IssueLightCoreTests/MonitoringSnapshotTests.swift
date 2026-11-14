import Foundation
import XCTest
@testable import IssueLightCore

final class MonitoringSnapshotTests: XCTestCase {
    func testDecoderMapsIcingaHostAndServiceProblemsToProviderNeutralIssues() throws {
        let sourceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let hostData = Data(
            #"{"results":[{"attrs":{"acknowledgement":0,"check_attempt":3,"display_name":"Database 1","downtime_depth":0,"last_check_result":{"output":"Host unreachable\nsecond line"},"last_state_change":1799992800,"max_check_attempts":3,"name":"db-1","state":1},"name":"db-1","type":"Host"}]}"#.utf8
        )
        let serviceData = Data(
            #"{"results":[{"attrs":{"acknowledgement":1,"check_attempt":2,"display_name":"Disk /","downtime_depth":0,"host_name":"db-1","last_check_result":{"output":"DISK WARNING - 82% used"},"last_state_change":1799996400,"max_check_attempts":4,"name":"disk-root","state":1},"name":"db-1!disk-root","type":"Service"},{"attrs":{"acknowledgement":0,"display_name":"Replication","downtime_depth":2,"host_name":"db-1","last_check_result":{"output":"UNKNOWN - no sample"},"name":"replication","state":3},"name":"db-1!replication","type":"Service"}]}"#.utf8
        )

        let snapshot = try Icinga2SnapshotDecoder().decode(
            sourceID: sourceID,
            observedAt: observedAt,
            hostData: hostData,
            serviceData: serviceData
        )

        XCTAssertEqual(snapshot.sourceID, sourceID)
        XCTAssertEqual(snapshot.observedAt, observedAt)
        XCTAssertEqual(snapshot.issues.count, 3)
        XCTAssertEqual(
            snapshot.issues[0],
            MonitoringIssue(
                sourceID: sourceID,
                nativeID: "db-1",
                kind: .host,
                hostName: "db-1",
                serviceName: nil,
                displayName: "Database 1",
                severity: .critical,
                summary: "Host unreachable",
                stateChangedAt: Date(timeIntervalSince1970: 1_799_992_800),
                checkAttempt: 3,
                maxCheckAttempts: 3,
                isAcknowledged: false,
                isInDowntime: false
            )
        )
        let diskIssue = try XCTUnwrap(snapshot.issues.first { $0.nativeID == "db-1!disk-root" })
        XCTAssertEqual(diskIssue.checkAttempt, 2)
        XCTAssertEqual(diskIssue.maxCheckAttempts, 4)
        let replicationIssue = try XCTUnwrap(snapshot.issues.first { $0.nativeID == "db-1!replication" })
        XCTAssertEqual(replicationIssue.stateChangedAt, nil)
        XCTAssertTrue(snapshot.issues[0].requiresAttention)
        XCTAssertFalse(snapshot.issues[1].requiresAttention)
        XCTAssertFalse(snapshot.issues[2].requiresAttention)
        XCTAssertEqual(snapshot.highestAttentionSeverity, .critical)
    }

    func testDecoderIgnoresHealthyResultsAndSortsActionableProblemsFirst() throws {
        let sourceID = UUID()
        let hostData = Data(
            #"{"results":[{"attrs":{"acknowledgement":0,"display_name":"Healthy","downtime_depth":0,"last_check_result":{"output":"UP"},"name":"healthy","state":0},"name":"healthy","type":"Host"}]}"#.utf8
        )
        let serviceData = Data(
            #"{"results":[{"attrs":{"acknowledgement":0,"display_name":"CPU","downtime_depth":0,"host_name":"app-1","last_check_result":{"output":"WARNING"},"name":"cpu","state":1},"name":"app-1!cpu","type":"Service"},{"attrs":{"acknowledgement":1,"display_name":"TLS","downtime_depth":0,"host_name":"edge-1","last_check_result":{"output":"CRITICAL"},"name":"tls","state":2},"name":"edge-1!tls","type":"Service"}]}"#.utf8
        )

        let snapshot = try Icinga2SnapshotDecoder().decode(
            sourceID: sourceID,
            observedAt: .distantPast,
            hostData: hostData,
            serviceData: serviceData
        )

        XCTAssertEqual(snapshot.issues.map(\.displayName), ["CPU", "TLS"])
        XCTAssertEqual(snapshot.actionableIssues.map(\.displayName), ["CPU"])
        XCTAssertEqual(snapshot.highestAttentionSeverity, .warning)
    }

    func testIssueIdentityIsStableAndNamespacedBySourceAndKind() {
        let issue = MonitoringIssue(
            sourceID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            nativeID: "host-1!disk",
            kind: .service,
            hostName: "host-1",
            serviceName: "disk",
            displayName: "Disk",
            severity: .critical,
            summary: "Disk full",
            isAcknowledged: false,
            isInDowntime: false
        )

        XCTAssertEqual(
            issue.id,
            "11111111-1111-1111-1111-111111111111:service:host-1!disk"
        )
    }

    func testDecoderSortsHostsBeforeServicesAndUsesDisplayNameAsFinalTieBreaker() throws {
        let hostData = Data(
            #"{"results":[{"attrs":{"acknowledgement":0,"display_name":"Host","downtime_depth":0,"name":"host-1","state":1},"name":"host-1","type":"Host"}]}"#.utf8
        )
        let serviceData = Data(
            #"{"results":[{"attrs":{"acknowledgement":0,"display_name":"Beta","downtime_depth":0,"host_name":"host-1","name":"beta","state":2},"name":"host-1!beta","type":"Service"},{"attrs":{"acknowledgement":0,"display_name":"Alpha","downtime_depth":0,"host_name":"host-1","name":"alpha","state":2},"name":"host-1!alpha","type":"Service"}]}"#.utf8
        )

        let snapshot = try Icinga2SnapshotDecoder().decode(
            sourceID: UUID(),
            observedAt: .distantPast,
            hostData: hostData,
            serviceData: serviceData
        )

        XCTAssertEqual(snapshot.issues.map(\.displayName), ["Host", "Alpha", "Beta"])
    }

    func testDecoderUsesNativeIdentifierWhenDisplayNamesAreEqual() throws {
        let serviceData = Data(
            #"{"results":[{"attrs":{"acknowledgement":0,"display_name":"Disk","downtime_depth":0,"host_name":"host-1","name":"zeta","state":2},"name":"host-1!zeta","type":"Service"},{"attrs":{"acknowledgement":0,"display_name":"Disk","downtime_depth":0,"host_name":"host-1","name":"alpha","state":2},"name":"host-1!alpha","type":"Service"}]}"#.utf8
        )

        let snapshot = try Icinga2SnapshotDecoder().decode(
            sourceID: UUID(),
            observedAt: .distantPast,
            hostData: Data(#"{"results":[]}"#.utf8),
            serviceData: serviceData
        )

        XCTAssertEqual(snapshot.issues.map(\.nativeID), ["host-1!alpha", "host-1!zeta"])
    }

    func testDecoderRejectsMalformedOrIncompleteProviderPayloads() {
        let validEmpty = Data(#"{"results":[]}"#.utf8)
        let missingResults = Data(#"{"status":"ok"}"#.utf8)
        let incompleteIssue = Data(
            #"{"results":[{"attrs":{"name":"host-1","state":1},"name":"host-1","type":"Host"}]}"#.utf8
        )

        XCTAssertThrowsError(
            try Icinga2SnapshotDecoder().decode(
                sourceID: UUID(),
                observedAt: .now,
                hostData: missingResults,
                serviceData: validEmpty
            )
        )
        XCTAssertThrowsError(
            try Icinga2SnapshotDecoder().decode(
                sourceID: UUID(),
                observedAt: .now,
                hostData: incompleteIssue,
                serviceData: validEmpty
            )
        )
    }
}
