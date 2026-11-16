import IssueLightCore
import XCTest

@MainActor
final class IssueNotificationTests: XCTestCase {
    func testFirstSnapshotEstablishesBaselineWithoutInterrupting() {
        var planner = IssueNotificationPlanner()
        let source = sourceID()
        let first = issue(sourceID: source, id: "disk", severity: .critical)

        let plan = planner.update(
            sourceID: source,
            actionableIssues: [first],
            policy: .criticalOnly
        )

        XCTAssertNil(plan.summary)
        XCTAssertFalse(plan.removesDeliveredSummary)
    }

    func testNewEligibleIssueCreatesOneStableSourceSummaryWithoutRepeating() throws {
        var planner = IssueNotificationPlanner()
        let source = sourceID()
        _ = planner.update(sourceID: source, actionableIssues: [], policy: .warningAndCritical)
        let warning = issue(sourceID: source, id: "disk", severity: .warning)
        let critical = issue(sourceID: source, id: "database", severity: .critical)

        let changed = planner.update(
            sourceID: source,
            actionableIssues: [warning, critical],
            policy: .warningAndCritical
        )
        let unchanged = planner.update(
            sourceID: source,
            actionableIssues: [warning, critical],
            policy: .warningAndCritical
        )

        let summary = try XCTUnwrap(changed.summary)
        XCTAssertEqual(summary.identifier, "issuelight.source.\(source.uuidString.lowercased())")
        XCTAssertEqual(summary.issueCount, 2)
        XCTAssertEqual(summary.highestSeverity, .critical)
        XCTAssertEqual(summary.issueForNavigation, critical)
        XCTAssertNil(unchanged.summary)
        XCTAssertFalse(unchanged.removesDeliveredSummary)
    }

    func testThresholdCrossingNotifiesButExistingEligibleIssueDoesNotRepeat() {
        var planner = IssueNotificationPlanner()
        let source = sourceID()
        let warning = issue(sourceID: source, id: "latency", severity: .warning)
        _ = planner.update(sourceID: source, actionableIssues: [warning], policy: .criticalOnly)
        let critical = issue(sourceID: source, id: "latency", severity: .critical)

        let escalated = planner.update(
            sourceID: source,
            actionableIssues: [critical],
            policy: .criticalOnly
        )
        let unchanged = planner.update(
            sourceID: source,
            actionableIssues: [critical],
            policy: .criticalOnly
        )

        XCTAssertEqual(escalated.summary?.highestSeverity, .critical)
        XCTAssertNil(unchanged.summary)
    }

    func testSeverityEscalationNotifiesOnceWhenIssueWasAlreadyEligible() {
        var planner = IssueNotificationPlanner()
        let source = sourceID()
        let warning = issue(sourceID: source, id: "latency", severity: .warning)
        let critical = issue(sourceID: source, id: "latency", severity: .critical)
        _ = planner.update(
            sourceID: source,
            actionableIssues: [warning],
            policy: .warningAndCritical
        )

        let escalated = planner.update(
            sourceID: source,
            actionableIssues: [critical],
            policy: .warningAndCritical
        )
        let unchanged = planner.update(
            sourceID: source,
            actionableIssues: [critical],
            policy: .warningAndCritical
        )

        XCTAssertEqual(escalated.summary?.highestSeverity, .critical)
        XCTAssertNil(unchanged.summary)
    }

    func testFullRecoveryRemovesDeliveredSummaryAndReappearanceNotifiesAgain() {
        var planner = IssueNotificationPlanner()
        let source = sourceID()
        let problem = issue(sourceID: source, id: "host", severity: .critical)
        _ = planner.update(sourceID: source, actionableIssues: [], policy: .allAttentionStates)
        _ = planner.update(sourceID: source, actionableIssues: [problem], policy: .allAttentionStates)

        let recovery = planner.update(
            sourceID: source,
            actionableIssues: [],
            policy: .allAttentionStates
        )
        let recurrence = planner.update(
            sourceID: source,
            actionableIssues: [problem],
            policy: .allAttentionStates
        )

        XCTAssertTrue(recovery.removesDeliveredSummary)
        XCTAssertNotNil(recurrence.summary)
    }

    func testDisabledPolicyRemovesSummaryAndResetsTheNextEnabledSnapshot() {
        var planner = IssueNotificationPlanner()
        let source = sourceID()
        let problem = issue(sourceID: source, id: "host", severity: .critical)
        _ = planner.update(sourceID: source, actionableIssues: [], policy: .criticalOnly)
        _ = planner.update(sourceID: source, actionableIssues: [problem], policy: .criticalOnly)

        let disabled = planner.update(
            sourceID: source,
            actionableIssues: [problem],
            policy: .disabled
        )
        let enabledAgain = planner.update(
            sourceID: source,
            actionableIssues: [problem],
            policy: .criticalOnly
        )

        XCTAssertTrue(disabled.removesDeliveredSummary)
        XCTAssertNil(enabledAgain.summary)
    }

    func testPolicyStorePersistsPerSourceAndRemovesDeletedSources() {
        let suiteName = "IssueNotificationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = sourceID()
        let second = sourceID()
        let store = IssueNotificationPolicyStore(defaults: defaults)

        store.set(.criticalOnly, for: first)
        store.set(.allAttentionStates, for: second)
        let reloaded = IssueNotificationPolicyStore(defaults: defaults)
        reloaded.reconcile(sourceIDs: [second])

        XCTAssertEqual(reloaded.policy(for: first), .disabled)
        XCTAssertEqual(reloaded.policy(for: second), .allAttentionStates)
    }

    func testUnauthoritativeEmptySourceListDoesNotEraseStoredPolicy() {
        let suiteName = "IssueNotificationLifecycleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let source = sourceID()
        let store = IssueNotificationPolicyStore(defaults: defaults)
        store.set(.criticalOnly, for: source)
        let coordinator = IssueNotificationCoordinator(
            policyStore: store,
            notificationCenter: RecordingNotificationCenterClient(),
            locale: Locale(identifier: "en")
        )

        coordinator.update(sources: [], snapshots: [:], isAuthoritative: false)

        XCTAssertEqual(store.policy(for: source), .criticalOnly)
    }

    func testSessionPreparationClearsStaleSummariesAndReadsAuthorizationWithoutPrompting() async {
        let client = RecordingNotificationCenterClient()
        client.authorizationStatus = .authorized
        let coordinator = IssueNotificationCoordinator(
            notificationCenter: client,
            locale: Locale(identifier: "en")
        )

        await coordinator.prepareForSession()

        XCTAssertEqual(client.removedAllCount, 1)
        XCTAssertEqual(client.authorizationRequests, 0)
        XCTAssertEqual(coordinator.authorization, .authorized)
    }

    func testCoordinatorRequestsPermissionOnlyAfterExplicitOptInAndKeepsContentPrivate() async throws {
        let suiteName = "IssueNotificationCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let source = sourceID()
        let client = RecordingNotificationCenterClient()
        let coordinator = IssueNotificationCoordinator(
            policyStore: IssueNotificationPolicyStore(defaults: defaults),
            notificationCenter: client,
            locale: Locale(identifier: "en")
        )

        await coordinator.refreshAuthorizationStatus()
        XCTAssertEqual(client.authorizationRequests, 0)

        await coordinator.setPolicy(.criticalOnly, for: source)
        coordinator.update(
            sources: [monitoringSource(id: source)],
            snapshots: [source: MonitoringSnapshot(sourceID: source, observedAt: Date(), issues: [])]
        )
        coordinator.update(
            sources: [monitoringSource(id: source)],
            snapshots: [
                source: MonitoringSnapshot(
                    sourceID: source,
                    observedAt: Date(),
                    issues: [issue(sourceID: source, id: "private-host", severity: .critical)]
                ),
            ]
        )
        await coordinator.waitForPendingWork()

        XCTAssertEqual(client.authorizationRequests, 1)
        let delivered = try XCTUnwrap(client.delivered.first)
        XCTAssertFalse(delivered.title.contains("private-host"))
        XCTAssertFalse(delivered.body.contains("private-host"))
        XCTAssertNil(delivered.title.range(of: "Production", options: .caseInsensitive))
        XCTAssertEqual(delivered.interruption, .active)
    }

    func testNotificationNavigationUsesConfiguredWebAccessPath() async throws {
        let suiteName = "IssueNotificationNavigationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let source = sourceID()
        let client = RecordingNotificationCenterClient()
        client.authorizationStatus = .authorized
        let coordinator = IssueNotificationCoordinator(
            policyStore: IssueNotificationPolicyStore(defaults: defaults),
            notificationCenter: client,
            locale: Locale(identifier: "en")
        )
        let url = URL(string: "https://monitoring.example.test/icingadb/hosts/private-host")!
        let tunnel = SSHTunnelConfiguration(
            bastionHost: "bastion.example.test",
            username: "operator"
        )
        var openedTarget: IssueWebTarget?
        coordinator.configureNavigation(
            issueURL: { _ in url },
            target: { sourceID, responseURL in
                IssueWebTarget(
                    sourceID: sourceID,
                    url: responseURL,
                    automaticSSHTunnel: tunnel
                )
            },
            open: { target in
                openedTarget = target
            }
        )
        await coordinator.refreshAuthorizationStatus()
        await coordinator.setPolicy(.criticalOnly, for: source)
        coordinator.update(
            sources: [monitoringSource(id: source)],
            snapshots: [source: MonitoringSnapshot(sourceID: source, observedAt: Date(), issues: [])]
        )
        coordinator.update(
            sources: [monitoringSource(id: source)],
            snapshots: [
                source: MonitoringSnapshot(
                    sourceID: source,
                    observedAt: Date(),
                    issues: [issue(sourceID: source, id: "database", severity: .critical)]
                ),
            ]
        )
        await coordinator.waitForPendingWork()
        let identifier = try XCTUnwrap(client.delivered.first?.identifier)

        client.simulateResponse(identifier: identifier)
        await coordinator.waitForPendingWork()

        XCTAssertEqual(openedTarget?.sourceID, source)
        XCTAssertEqual(openedTarget?.url, url)
        XCTAssertEqual(openedTarget?.automaticSSHTunnel, tunnel)
    }

    private func sourceID() -> UUID {
        UUID()
    }

    private func monitoringSource(id: UUID) -> MonitoringSource {
        MonitoringSource(
            id: id,
            name: "Production",
            providerID: Icinga2Provider.id,
            endpoint: URL(string: "https://icinga.example.test:5665")!,
            authentication: .basic(username: "operator")
        )
    }

    private func issue(
        sourceID: UUID,
        id: String,
        severity: MonitoringSeverity
    ) -> MonitoringIssue {
        MonitoringIssue(
            sourceID: sourceID,
            nativeID: id,
            kind: .service,
            hostName: "private-host",
            serviceName: "Disk",
            displayName: "Disk",
            severity: severity,
            summary: "private output",
            isAcknowledged: false,
            isInDowntime: false
        )
    }
}

@MainActor
private final class RecordingNotificationCenterClient: IssueNotificationCenterClient {
    var authorizationStatus = IssueNotificationAuthorization.notDetermined
    var authorizationRequests = 0
    var delivered: [IssueNotificationContent] = []
    var removedIdentifiers: [String] = []
    var removedAllCount = 0
    var responseHandler: ((String) -> Void)?

    func setResponseHandler(_ handler: @escaping @MainActor (String) -> Void) {
        responseHandler = handler
    }

    func currentAuthorization() async -> IssueNotificationAuthorization {
        authorizationStatus
    }

    func requestAuthorization() async -> IssueNotificationAuthorization {
        authorizationRequests += 1
        authorizationStatus = .authorized
        return authorizationStatus
    }

    func deliver(_ content: IssueNotificationContent) async throws {
        delivered.append(content)
    }

    func remove(identifier: String) {
        removedIdentifiers.append(identifier)
    }

    func removeAll() {
        removedAllCount += 1
    }

    func simulateResponse(identifier: String) {
        responseHandler?(identifier)
    }
}
