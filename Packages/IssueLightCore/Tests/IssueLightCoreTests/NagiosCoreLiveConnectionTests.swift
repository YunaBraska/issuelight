import XCTest
@testable import IssueLightCore

final class NagiosCoreLiveConnectionTests: XCTestCase {
    func testDiscoveryAuthenticationAndRealSnapshot() async throws {
        let (endpoint, password) = try liveEnvironment()
        let source = liveSource(endpoint: endpoint)
        let provider = try XCTUnwrap(ProviderRegistry.builtIn().provider(for: source.providerID))

        XCTAssertTrue(provider.endpointCandidates(from: endpoint.deletingLastPathComponent().absoluteString).contains(endpoint))

        let connected = await provider.testConnection(
            to: source,
            access: ProviderAccess(credential: .password(password))
        )
        let rejected = await provider.testConnection(
            to: source,
            access: ProviderAccess(credential: .password("wrong-password"))
        )
        let snapshotResult = await provider.loadSnapshot(
            from: source,
            access: ProviderAccess(credential: .password(password))
        )

        XCTAssertEqual(connected, .connected)
        XCTAssertEqual(rejected, .failed(.authentication))
        guard case .loaded(let snapshot) = snapshotResult else {
            return XCTFail("Expected a live Nagios Core snapshot, got \(snapshotResult)")
        }
        let host = try XCTUnwrap(snapshot.issues.first(where: { $0.kind == .host }))
        let service = try XCTUnwrap(snapshot.issues.first(where: { $0.kind == .service }))
        XCTAssertEqual(host.hostName, "issuelight-live")
        XCTAssertEqual(host.severity, .critical)
        XCTAssertEqual(host.summary, "DOWN - IssueLight live lab")
        XCTAssertEqual(service.serviceName, "IssueLight Critical Service")
        XCTAssertEqual(service.severity, .critical)
        XCTAssertEqual(service.summary, "CRITICAL - IssueLight live lab")
        XCTAssertEqual(service.checkAttempt, 1)
        XCTAssertEqual(service.maxCheckAttempts, 1)
        XCTAssertFalse(service.isAcknowledged)
        XCTAssertFalse(service.isInDowntime)
        assertSourceRulesForIssue(host)
        assertSourceRulesForIssue(service)
        XCTAssertEqual(host.activity.notificationsEnabled, false)
        XCTAssertEqual(service.activity.isSoftState, false)
        XCTAssertEqual(service.activity.hostIsInDowntime, false)
        _ = try await assertPendingChecksFromLiveProvider(
            provider, source: source, access: ProviderAccess(credential: .password(password)),
            initialSnapshot: snapshot, host: "issuelight-live", service: "IssueLight Pending Service"
        )
    }

    func testRealCSRFProtectedCommandsUseTheProviderBoundary() async throws {
        let (endpoint, password) = try liveEnvironment()
        let source = liveSource(endpoint: endpoint)
        let provider = try XCTUnwrap(ProviderRegistry.builtIn().provider(for: source.providerID))
        let access = ProviderAccess(credential: .password(password))
        let snapshotResult = await provider.loadSnapshot(from: source, access: access)
        guard case .loaded(let snapshot) = snapshotResult,
              let issue = snapshot.issues.first(where: {
                  $0.serviceName == "IssueLight Critical Service"
              }) else {
            return XCTFail("Expected the deterministic Nagios Core service problem")
        }

        let acknowledgement = await provider.perform(
            .acknowledge(author: "IssueLight", comment: "Live integration test"),
            on: issue,
            from: source,
            access: access
        )
        let start = Date()
        let downtime = await provider.perform(
            .scheduleDowntime(
                author: "IssueLight",
                comment: "Live integration test",
                start: start,
                end: start.addingTimeInterval(300)
            ),
            on: issue,
            from: source,
            access: access
        )

        XCTAssertEqual(acknowledgement, .completed)
        XCTAssertEqual(downtime, .completed)

        var updatedIssue: MonitoringIssue?
        for _ in 0..<20 {
            if case .loaded(let updatedSnapshot) = await provider.loadSnapshot(
                from: source,
                access: access
            ),
               let candidate = updatedSnapshot.issues.first(where: { $0.id == issue.id }),
               candidate.isAcknowledged,
               candidate.isInDowntime {
                updatedIssue = candidate
                break
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTAssertEqual(updatedIssue?.isAcknowledged, true)
        XCTAssertEqual(updatedIssue?.isInDowntime, true)
        assertSourceRulesForIssue(try XCTUnwrap(updatedIssue))

        let recheck = await provider.perform(.recheck, on: issue, from: source, access: access)
        XCTAssertEqual(recheck, .completed)
    }

    private func liveEnvironment() throws -> (URL, String) {
        let environment = ProcessInfo.processInfo.environment
        guard let endpointValue = environment["ISSUELIGHT_LIVE_NAGIOS_URL"],
              let endpoint = URL(string: endpointValue),
              let password = environment["ISSUELIGHT_NAGIOS_PASSWORD"] else {
            throw XCTSkip("Live Nagios Core environment is not configured")
        }
        return (endpoint, password)
    }

    private func liveSource(endpoint: URL) -> MonitoringSource {
        MonitoringSource(
            name: "Live Nagios Core",
            providerID: NagiosCoreProvider.id,
            endpoint: endpoint,
            authentication: .basic(username: "nagiosadmin")
        )
    }
}
