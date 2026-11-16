import IssueLightCore
import XCTest

@MainActor
final class PanelFilterSettingsTests: XCTestCase {
    func testFiltersPersistAndMatchSourceSeverityAndCoverage() {
        let suiteName = "PanelFilterSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let sourceID = UUID()
        let issue = MonitoringIssue(
            sourceID: sourceID,
            nativeID: "disk",
            kind: .service,
            hostName: "db-01",
            serviceName: "Disk",
            displayName: "Disk",
            severity: .critical,
            summary: "CRITICAL",
            isAcknowledged: false,
            isInDowntime: false
        )
        let filters = PanelFilterSettings(defaults: defaults)

        filters.sourceID = sourceID.uuidString.lowercased()
        filters.severity = .critical
        filters.coverage = .attention
        filters.setHost(PanelHostSelection(issue: issue), selected: true)

        XCTAssertTrue(filters.includes(issue, isCovered: false))
        XCTAssertFalse(filters.includes(issue, isCovered: true))
        let reloaded = PanelFilterSettings(defaults: defaults)
        XCTAssertEqual(reloaded.sourceID, sourceID.uuidString.lowercased())
        XCTAssertEqual(reloaded.severity, .critical)
        XCTAssertEqual(reloaded.coverage, .attention)
        XCTAssertEqual(reloaded.hostSelections, [PanelHostSelection(issue: issue)])
    }

    func testHostSelectionDistinguishesSameHostNameAcrossSourcesAndFiltersMenuIssues() {
        let suiteName = "PanelHostFilterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let firstSource = UUID()
        let secondSource = UUID()
        let firstIssue = issue(sourceID: firstSource, hostName: "database")
        let secondIssue = issue(sourceID: secondSource, hostName: "database")
        let filters = PanelFilterSettings(defaults: defaults)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }

        filters.setHost(PanelHostSelection(issue: firstIssue), selected: true)

        XCTAssertTrue(filters.includesHost(firstIssue))
        XCTAssertFalse(filters.includesHost(secondIssue))
        XCTAssertEqual([firstIssue, secondIssue].filter(filters.includesHost), [firstIssue])
    }

    func testRemovedSourceResetsOnlySourceFilter() {
        let suiteName = "PanelFilterSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let filters = PanelFilterSettings(defaults: defaults)
        let removedSourceID = UUID()
        filters.sourceID = removedSourceID.uuidString.lowercased()
        filters.severity = .warning
        filters.setHost(
            PanelHostSelection(sourceID: removedSourceID, hostName: "retired-host"),
            selected: true
        )

        filters.reconcile(sourceIDs: [UUID()])

        XCTAssertEqual(filters.sourceID, "")
        XCTAssertEqual(filters.severity, .warning)
        XCTAssertTrue(filters.hostSelections.isEmpty)
    }

    func testInitialEmptySourceSnapshotDoesNotErasePersistedFilterBeforeLoadCompletes() {
        let suiteName = "PanelFilterSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let sourceID = UUID().uuidString.lowercased()
        defaults.set(sourceID, forKey: "panel.filter.source")
        let filters = PanelFilterSettings(defaults: defaults)

        filters.reconcile(sourceIDs: [], isAuthoritative: false)

        XCTAssertEqual(filters.sourceID, sourceID)
    }

    func testMissingHostRemainsSelectedWhileItsSourceStillExists() {
        let suiteName = "PanelHostLifecycleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let sourceID = UUID()
        let selection = PanelHostSelection(sourceID: sourceID, hostName: "temporarily-healthy")
        let filters = PanelFilterSettings(defaults: defaults)
        filters.setHost(selection, selected: true)

        filters.reconcile(sourceIDs: [sourceID])

        XCTAssertEqual(filters.hostSelections, [selection])
    }

    private func issue(sourceID: UUID, hostName: String) -> MonitoringIssue {
        MonitoringIssue(
            sourceID: sourceID,
            nativeID: "\(hostName)!Disk",
            kind: .service,
            hostName: hostName,
            serviceName: "Disk",
            displayName: "Disk",
            severity: .critical,
            summary: "CRITICAL",
            isAcknowledged: false,
            isInDowntime: false
        )
    }
}
