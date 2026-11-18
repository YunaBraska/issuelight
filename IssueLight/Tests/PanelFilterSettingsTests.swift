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
        filters.setHost(PanelHostSelection(issue: issue), excluded: true)

        XCTAssertFalse(filters.includes(issue, isCovered: false))
        let reloaded = PanelFilterSettings(defaults: defaults)
        XCTAssertEqual(reloaded.sourceID, sourceID.uuidString.lowercased())
        XCTAssertEqual(reloaded.severity, .critical)
        XCTAssertEqual(reloaded.coverage, .attention)
        XCTAssertEqual(reloaded.excludedHosts, [PanelHostSelection(issue: issue)])
    }

    func testHostExclusionDistinguishesSameHostNameAcrossSourcesAndFiltersMenuIssues() {
        let suiteName = "PanelHostFilterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let firstSource = UUID()
        let secondSource = UUID()
        let firstIssue = issue(sourceID: firstSource, hostName: "database")
        let secondIssue = issue(sourceID: secondSource, hostName: "database")
        let filters = PanelFilterSettings(defaults: defaults)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }

        filters.setHost(PanelHostSelection(issue: firstIssue), excluded: true)

        XCTAssertFalse(filters.includesHost(firstIssue))
        XCTAssertTrue(filters.includesHost(secondIssue))
        XCTAssertEqual([firstIssue, secondIssue].filter(filters.includesHost), [secondIssue])
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
            excluded: true
        )

        filters.reconcile(sourceIDs: [UUID()])

        XCTAssertEqual(filters.sourceID, "")
        XCTAssertEqual(filters.severity, .warning)
        XCTAssertTrue(filters.excludedHosts.isEmpty)
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

    func testMissingHostRemainsExcludedWhileItsSourceStillExists() {
        let suiteName = "PanelHostLifecycleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let sourceID = UUID()
        let selection = PanelHostSelection(sourceID: sourceID, hostName: "temporarily-healthy")
        let filters = PanelFilterSettings(defaults: defaults)
        filters.setHost(selection, excluded: true)

        filters.reconcile(sourceIDs: [sourceID])

        XCTAssertEqual(filters.excludedHosts, [selection])
    }

    func testTwoExclusionsLeaveTheOther198HostsVisible() {
        let suiteName = "PanelHostScaleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let sourceID = UUID()
        let issues = (0..<200).map { index in
            issue(sourceID: sourceID, hostName: String(format: "host-%03d", index))
        }
        let filters = PanelFilterSettings(defaults: defaults)

        filters.setHost(PanelHostSelection(issue: issues[17]), excluded: true)
        filters.setHost(PanelHostSelection(issue: issues[163]), excluded: true)

        XCTAssertEqual(issues.filter(filters.includesHost).count, 198)
        XCTAssertFalse(filters.includesHost(issues[17]))
        XCTAssertFalse(filters.includesHost(issues[163]))
        XCTAssertTrue(filters.includesHost(issues[162]))
    }

    func testLegacyPositiveHostFilterIsClearedInsteadOfBeingInverted() throws {
        let suiteName = "PanelHostMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let legacySelection = PanelHostSelection(sourceID: UUID(), hostName: "legacy-host")
        defaults.set(try JSONEncoder().encode(Set([legacySelection])), forKey: "panel.filter.hosts")

        let filters = PanelFilterSettings(defaults: defaults)

        XCTAssertTrue(filters.excludedHosts.isEmpty)
        XCTAssertNil(defaults.data(forKey: "panel.filter.hosts"))
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
