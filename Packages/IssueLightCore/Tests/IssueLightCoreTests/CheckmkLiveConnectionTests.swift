import XCTest
@testable import IssueLightCore

final class CheckmkLiveConnectionTests: XCTestCase {
    func testAutomationUserConnectsAndWrongSecretIsRejected() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let endpointValue = environment["ISSUELIGHT_LIVE_CHECKMK_URL"],
              let endpoint = URL(string: endpointValue),
              let secret = environment["ISSUELIGHT_CHECKMK_API_SECRET"] else {
            throw XCTSkip("Live Checkmk environment is not configured")
        }
        let source = liveSource(endpoint: endpoint)
        let provider = try XCTUnwrap(ProviderRegistry.builtIn().provider(for: source.providerID))

        let connected = await provider.testConnection(
            to: source,
            access: ProviderAccess(credential: .apiKey(secret))
        )
        let rejected = await provider.testConnection(
            to: source,
            access: ProviderAccess(credential: .apiKey("wrong-secret"))
        )

        XCTAssertEqual(connected, .connected)
        XCTAssertEqual(rejected, .failed(.authentication))
    }

    func testRealSnapshotAndSupportedActionsUseTheProviderBoundary() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let endpointValue = environment["ISSUELIGHT_LIVE_CHECKMK_URL"],
              let endpoint = URL(string: endpointValue),
              let secret = environment["ISSUELIGHT_CHECKMK_API_SECRET"] else {
            throw XCTSkip("Live Checkmk environment is not configured")
        }
        let source = liveSource(endpoint: endpoint)
        let provider = try XCTUnwrap(ProviderRegistry.builtIn().provider(for: source.providerID))
        let access = ProviderAccess(credential: .apiKey(secret))

        let snapshotResult = await provider.loadSnapshot(from: source, access: access)
        guard case .loaded(let snapshot) = snapshotResult else {
            return XCTFail("Expected a live Checkmk snapshot, got \(snapshotResult)")
        }
        let issue = try XCTUnwrap(
            snapshot.issues.first(where: {
                $0.kind == .host && $0.hostName == "issuelight-live"
            })
        )
        XCTAssertEqual(issue.severity, .critical)
        XCTAssertEqual(issue.summary, "DOWN - IssueLight live lab")
        XCTAssertFalse(issue.isAcknowledged)
        XCTAssertFalse(issue.isInDowntime)
        XCTAssertEqual(provider.supportedActions(for: source), [.acknowledge, .scheduleDowntime])

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
    }

    private func liveSource(endpoint: URL) -> MonitoringSource {
        MonitoringSource(
            name: "Live Checkmk",
            providerID: CheckmkProvider.id,
            endpoint: endpoint,
            authentication: .apiKey(username: "cmkadmin")
        )
    }
}
