import XCTest
@testable import IssueLightCore

final class ThrukLiveConnectionTests: XCTestCase {
    func testBasicAuthenticationConnectsAndWrongPasswordIsRejected() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let endpointValue = environment["ISSUELIGHT_LIVE_THRUK_URL"],
              let endpoint = URL(string: endpointValue),
              let password = environment["ISSUELIGHT_THRUK_BASIC_PASSWORD"] else {
            throw XCTSkip("Live Thruk environment is not configured")
        }
        let source = MonitoringSource(
            name: "Live Thruk",
            providerID: ThrukProvider.id,
            endpoint: endpoint,
            authentication: .basic(username: "omdadmin"),
            serverTrust: .disabled
        )
        let provider = try XCTUnwrap(ProviderRegistry.builtIn().provider(for: source.providerID))

        let connected = await provider.testConnection(
            to: source,
            access: ProviderAccess(credential: .password(password))
        )
        let rejected = await provider.testConnection(
            to: source,
            access: ProviderAccess(credential: .password("wrong-password"))
        )

        XCTAssertEqual(connected, .connected)
        XCTAssertEqual(rejected, .failed(.authentication))
    }

    func testSystemTrustRejectsTheLabCertificate() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let endpointValue = environment["ISSUELIGHT_LIVE_THRUK_URL"],
              let endpoint = URL(string: endpointValue),
              let password = environment["ISSUELIGHT_THRUK_BASIC_PASSWORD"] else {
            throw XCTSkip("Live Thruk environment is not configured")
        }
        let source = MonitoringSource(
            name: "Untrusted live Thruk",
            providerID: ThrukProvider.id,
            endpoint: endpoint,
            authentication: .basic(username: "omdadmin")
        )
        let provider = try XCTUnwrap(ProviderRegistry.builtIn().provider(for: source.providerID))

        let result = await provider.testConnection(
            to: source,
            access: ProviderAccess(credential: .password(password))
        )

        XCTAssertEqual(result, .failed(.serverTrust))
    }

    func testSecretKeyHeaderConnectsThroughTheAPIKeyPath() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let endpointValue = environment["ISSUELIGHT_LIVE_THRUK_URL"],
              let endpoint = URL(string: endpointValue),
              let secretKey = environment["ISSUELIGHT_THRUK_API_KEY"] else {
            throw XCTSkip("Live Thruk environment is not configured")
        }
        let source = MonitoringSource(
            name: "Live Thruk API key",
            providerID: ThrukProvider.id,
            endpoint: endpoint,
            authentication: .apiKey(username: "omdadmin"),
            serverTrust: .disabled
        )
        let provider = try XCTUnwrap(ProviderRegistry.builtIn().provider(for: source.providerID))

        let result = await provider.testConnection(
            to: source,
            access: ProviderAccess(credential: .apiKey(secretKey))
        )

        XCTAssertEqual(result, .connected)
    }

    func testRealSnapshotAndCommandsUseTheProviderBoundary() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let endpointValue = environment["ISSUELIGHT_LIVE_THRUK_URL"],
              let endpoint = URL(string: endpointValue),
              let password = environment["ISSUELIGHT_THRUK_BASIC_PASSWORD"],
              let secretKey = environment["ISSUELIGHT_THRUK_API_KEY"] else {
            throw XCTSkip("Live Thruk environment is not configured")
        }
        var source = MonitoringSource(
            name: "Live Thruk actions",
            providerID: ThrukProvider.id,
            endpoint: endpoint,
            authentication: .basic(username: "omdadmin"),
            serverTrust: .disabled
        )
        let provider = try XCTUnwrap(ProviderRegistry.builtIn().provider(for: source.providerID))
        let access = ProviderAccess(credential: .password(password))
        let snapshotResult = await provider.loadSnapshot(from: source, access: access)
        guard case .loaded(let snapshot) = snapshotResult else {
            return XCTFail("Expected a live Thruk snapshot, got \(snapshotResult)")
        }
        let issue = try XCTUnwrap(
            snapshot.issues.first(where: {
                $0.hostName == "issuelight-live"
                    && $0.serviceName == "IssueLight Critical Service"
            })
        )

        XCTAssertEqual(issue.severity, .critical)
        XCTAssertEqual(issue.summary, "CRITICAL: IssueLight")
        XCTAssertEqual(issue.checkAttempt, 1)
        XCTAssertEqual(issue.maxCheckAttempts, 1)
        XCTAssertFalse(issue.isAcknowledged)
        XCTAssertFalse(issue.isInDowntime)

        let basicRecheck = await provider.perform(.recheck, on: issue, from: source, access: access)
        guard case .rejected(let basicRejection) = basicRecheck else {
            return XCTFail("Expected Thruk to reject a command without a CSRF token or API key")
        }
        XCTAssertEqual(
            basicRejection,
            "Thruk write actions require API-key authentication."
        )

        source.authentication = .apiKey(username: "omdadmin")
        let commandAccess = ProviderAccess(credential: .apiKey(secretKey))
        let recheck = await provider.perform(
            .recheck,
            on: issue,
            from: source,
            access: commandAccess
        )
        let acknowledgement = await provider.perform(
            .acknowledge(author: "IssueLight", comment: "Live integration test"),
            on: issue,
            from: source,
            access: commandAccess
        )
        let now = Date()
        let downtime = await provider.perform(
            .scheduleDowntime(
                author: "IssueLight",
                comment: "Live integration test",
                start: now,
                end: now.addingTimeInterval(300)
            ),
            on: issue,
            from: source,
            access: commandAccess
        )

        XCTAssertEqual(recheck, .completed)
        XCTAssertEqual(acknowledgement, .completed)
        XCTAssertEqual(downtime, .completed)

        var updatedIssue: MonitoringIssue?
        for _ in 0..<20 {
            if case .loaded(let updatedSnapshot) = await provider.loadSnapshot(
                from: source,
                access: commandAccess
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
}
