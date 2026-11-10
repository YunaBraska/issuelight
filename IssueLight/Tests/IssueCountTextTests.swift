import XCTest

final class IssueCountTextTests: XCTestCase {
    func testAttentionTextUsesGermanZeroSingularAndPluralForms() {
        XCTAssertEqual(IssueCountText.attention(0), "Keine Probleme benötigen Aufmerksamkeit")
        XCTAssertEqual(IssueCountText.attention(1), "1 Problem benötigt Aufmerksamkeit")
        XCTAssertEqual(IssueCountText.attention(2), "2 Probleme benötigen Aufmerksamkeit")
    }

    func testCoveredTextUsesGermanSingularAndPluralForms() {
        XCTAssertEqual(IssueCountText.covered(1), "1 Problem quittiert oder in Wartungszeit")
        XCTAssertEqual(IssueCountText.covered(2), "2 Probleme quittiert oder in Wartungszeit")
    }

    func testSourceStatusUsesGermanZeroSingularAndPluralForms() {
        XCTAssertEqual(IssueCountText.sourceStatus(0), "keine Probleme")
        XCTAssertEqual(IssueCountText.sourceStatus(1), "1 Problem")
        XCTAssertEqual(IssueCountText.sourceStatus(2), "2 Probleme")
    }
}
