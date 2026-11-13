import IssueLightCore
import SwiftUI
import XCTest

@MainActor
final class StatusWindowPerformanceTests: XCTestCase {
    func testSearchFiltersFiveThousandIssuesByObjectAndSourceText() throws {
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

    func testNativeStatusWindowRendersFiveThousandIssuesWithinFiveSeconds() throws {
        let fixture = issueFixture(count: 5_000)
        let view = StatusWindowContent(
            hasConfiguredSource: true,
            hasEnabledSource: true,
            hasActiveSnapshot: true,
            latestSuccessfulRefresh: Date(timeIntervalSince1970: 1_794_574_720),
            refreshState: .current,
            hasPartialRefreshFailure: false,
            failedSources: [],
            actionableIssues: fixture.issues,
            coveredIssues: [],
            sourceNames: fixture.sourceNames,
            refresh: {},
            openSources: {}
        )
        .environment(\.locale, Locale(identifier: "de_DE"))
        .environment(\.colorScheme, .light)

        let startedAt = ContinuousClock.now
        let renderedExpectedSize = NativeViewRenderer.exerciseWindow(
            for: view,
            size: CGSize(width: 760, height: 560)
        )
        let elapsed = ContinuousClock.now - startedAt
        let holdSeconds = Int(ProcessInfo.processInfo.environment["ISSUELIGHT_UI_HOLD_SECONDS"] ?? "0") ?? 0

        XCTAssertTrue(renderedExpectedSize)
        XCTAssertLessThan(elapsed, .seconds(holdSeconds + 5))
        if let outputPath = ProcessInfo.processInfo.environment["ISSUELIGHT_VOLUME_SCREENSHOT_PATH"] {
            let pngData = try NativeViewRenderer.pngData(
                for: view,
                size: CGSize(width: 760, height: 560)
            )
            XCTAssertGreaterThan(pngData.count, 50_000)
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
                isAcknowledged: false,
                isInDowntime: false
            )
        }
        return (
            issues,
            [productionID: "Produktion", homelabID: "Homelab"]
        )
    }
}
