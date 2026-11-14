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

        XCTAssertTrue(filters.includes(issue, isCovered: false))
        XCTAssertFalse(filters.includes(issue, isCovered: true))
        let reloaded = PanelFilterSettings(defaults: defaults)
        XCTAssertEqual(reloaded.sourceID, sourceID.uuidString.lowercased())
        XCTAssertEqual(reloaded.severity, .critical)
        XCTAssertEqual(reloaded.coverage, .attention)
    }

    func testRemovedSourceResetsOnlySourceFilter() {
        let suiteName = "PanelFilterSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let filters = PanelFilterSettings(defaults: defaults)
        filters.sourceID = UUID().uuidString.lowercased()
        filters.severity = .warning

        filters.reconcile(sourceIDs: [UUID()])

        XCTAssertEqual(filters.sourceID, "")
        XCTAssertEqual(filters.severity, .warning)
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
}
