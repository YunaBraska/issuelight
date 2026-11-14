import IssueLightCore
import XCTest

final class IssueCountTextTests: XCTestCase {
    private let locale = Locale(identifier: "de")

    func testAttentionTextUsesGermanZeroSingularAndPluralForms() {
        XCTAssertEqual(IssueCountText.attention(0, locale: locale), "Keine Probleme benötigen Aufmerksamkeit")
        XCTAssertEqual(IssueCountText.attention(1, locale: locale), "1 Problem benötigt Aufmerksamkeit")
        XCTAssertEqual(IssueCountText.attention(2, locale: locale), "2 Probleme benötigen Aufmerksamkeit")
    }

    func testCoveredTextUsesGermanSingularAndPluralForms() {
        XCTAssertEqual(IssueCountText.covered(1, locale: locale), "1 Problem quittiert oder in Wartungszeit")
        XCTAssertEqual(IssueCountText.covered(2, locale: locale), "2 Probleme quittiert oder in Wartungszeit")
    }

    func testSourceStatusUsesGermanZeroSingularAndPluralForms() {
        XCTAssertEqual(IssueCountText.sourceStatus(0, locale: locale), "keine Probleme")
        XCTAssertEqual(IssueCountText.sourceStatus(1, locale: locale), "1 Problem")
        XCTAssertEqual(IssueCountText.sourceStatus(2, locale: locale), "2 Probleme")
    }

    func testMenuBarCountsMatchNagBarSeverityOrderAndOmitZeros() {
        let sourceID = UUID()
        let fixtures: [(MonitoringObjectKind, MonitoringSeverity)] = [
            (.service, .warning),
            (.service, .critical),
            (.service, .unknown),
            (.host, .critical),
            (.host, .warning),
        ]
        let issues = fixtures.enumerated().map { index, fixture in
            MonitoringIssue(
                sourceID: sourceID,
                nativeID: "issue-\(index)",
                kind: fixture.0,
                hostName: "host-\(index)",
                serviceName: fixture.0 == .service ? "service-\(index)" : nil,
                displayName: "Host \(index)",
                severity: fixture.1,
                summary: "Fixture",
                isAcknowledged: false,
                isInDowntime: false
            )
        }

        XCTAssertEqual(MenuBarIssueCounts(issues: issues).compactText, "C:1 W:1 U:1 D:2")
        XCTAssertEqual(MenuBarIssueCounts(issues: []).compactText, "")
    }
}
