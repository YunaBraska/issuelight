import IssueLightCore
import SwiftUI
import XCTest

@MainActor
final class StatusMenuPerformanceTests: XCTestCase {
    func testSearchFiltersFiveThousandIssuesByObjectAndSourceText() {
        let fixture = issueFixture(count: 5_000)
        let sourceSearch = MonitoringIssueSearch(
            query: "  homelab  ",
            sourceNames: fixture.sourceNames
        )
        let objectSearch = MonitoringIssueSearch(
            query: "NEEDLE-TARGET",
            sourceNames: fixture.sourceNames
        )
        let emptySearch = MonitoringIssueSearch(query: "  ", sourceNames: fixture.sourceNames)
        let missingSearch = MonitoringIssueSearch(query: "not-present", sourceNames: fixture.sourceNames)

        let startedAt = ContinuousClock.now
        let sourceMatches = sourceSearch.filter(fixture.issues)
        let objectMatches = objectSearch.filter(fixture.issues)
        let elapsed = ContinuousClock.now - startedAt

        XCTAssertEqual(sourceMatches.count, 2_500)
        XCTAssertEqual(objectMatches.map(\.nativeID), ["service-04217"])
        XCTAssertEqual(emptySearch.filter(fixture.issues).count, 5_000)
        XCTAssertTrue(missingSearch.filter(fixture.issues).isEmpty)
        XCTAssertLessThan(elapsed, .seconds(1))
    }

    func testNativeMenuPanelRendersFiveThousandIssuesWithinFiveSeconds() throws {
        let fixture = issueFixture(count: 5_000)
        let view = StatusMenuContent(
            hasConfiguredSource: true,
            hasEnabledSource: true,
            hasActiveSnapshot: true,
            actionableIssues: fixture.issues,
            coveredIssues: [],
            sourceNames: fixture.sourceNames,
            filters: PanelFilterSettings(
                defaults: UserDefaults(suiteName: "StatusMenuPerformanceTests.\(UUID().uuidString)")!
            ),
            refreshState: .current,
            hasPartialRefreshFailure: false,
            supportedActions: { _ in [.recheck, .acknowledge, .scheduleDowntime] },
            activeActionIssueIDs: [],
            openSettings: {},
            openIssue: { _ in },
            openSSH: { _ in },
            openRDP: { _ in },
            hasSSH: { _ in true },
            hasRDP: { _ in true },
            performRecheck: { _ in },
            requestAcknowledgement: { _ in },
            requestDowntime: { _ in }
        )
        .environment(\.locale, Locale(identifier: "de_DE"))
        .environment(\.colorScheme, .light)

        let startedAt = ContinuousClock.now
        let renderedExpectedSize = NativeViewRenderer.exerciseWindow(
            for: view,
            size: CGSize(width: 720, height: 520)
        )
        let elapsed = ContinuousClock.now - startedAt
        let holdSeconds = Int(ProcessInfo.processInfo.environment["ISSUELIGHT_UI_HOLD_SECONDS"] ?? "0") ?? 0

        XCTAssertTrue(renderedExpectedSize)
        XCTAssertLessThan(elapsed, .seconds(holdSeconds + 5))
        if let outputPath = ProcessInfo.processInfo.environment["ISSUELIGHT_VOLUME_SCREENSHOT_PATH"] {
            let pngData = try NativeViewRenderer.pngData(
                for: view,
                size: CGSize(width: 720, height: 520)
            )
            XCTAssertGreaterThan(pngData.count, 30_000)
            try pngData.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        }
    }

    private func issueFixture(count: Int) -> (issues: [MonitoringIssue], sourceNames: [UUID: String]) {
        let productionID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let homelabID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        let issues = (0..<count).map { index in
            let sourceID = index.isMultiple(of: 2) ? productionID : homelabID
            let severity: MonitoringSeverity = index.isMultiple(of: 5) ? .warning : .critical
            return MonitoringIssue(
                sourceID: sourceID,
                nativeID: String(format: "service-%05d", index),
                kind: .service,
                hostName: String(format: "host-%03d", index % 200),
                serviceName: "Service \(index)",
                displayName: "Service \(index)",
                severity: severity,
                summary: index == 4_217
                    ? "CRITICAL: needle-target has failed"
                    : "\(severity == .warning ? "WARNING" : "CRITICAL"): deterministic volume fixture \(index)",
                stateChangedAt: Date(timeIntervalSince1970: 1_794_574_720 - Double(index % 86_400)),
                checkAttempt: index % 4 + 1,
                maxCheckAttempts: 4,
                isAcknowledged: false,
                isInDowntime: false
            )
        }
        return (
            issues,
            [productionID: "Production", homelabID: "Homelab"]
        )
    }
}
