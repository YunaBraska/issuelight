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
        let severities: [MonitoringSeverity] = [.warning, .critical, .unknown, .critical]
        let issues = severities.enumerated().map { index, severity in
            MonitoringIssue(
                sourceID: sourceID,
                nativeID: "issue-\(index)",
                kind: .host,
                hostName: "host-\(index)",
                serviceName: nil,
                displayName: "Host \(index)",
                severity: severity,
                summary: "Fixture",
                isAcknowledged: false,
                isInDowntime: false
            )
        }

        XCTAssertEqual(MenuBarIssueCounts(issues: issues).compactText, "C:2 W:1 U:1")
        XCTAssertEqual(MenuBarIssueCounts(issues: []).compactText, "")
    }
}
