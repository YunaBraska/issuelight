import IssueLightCore
import SwiftUI
import XCTest

@MainActor
final class StatusMenuInteractionTests: XCTestCase {
    func testSettingsButtonRespondsToPointerClick() {
        var openedSettings = false
        let view = StatusMenuContent(
            hasConfiguredSource: false,
            hasEnabledSource: false,
            hasActiveSnapshot: false,
            actionableIssues: [],
            coveredIssues: [],
            sourceNames: [:],
            filters: PanelFilterSettings(
                defaults: UserDefaults(suiteName: "StatusMenuInteractionTests.\(UUID().uuidString)")!
            ),
            refreshState: .notConfigured,
            hasPartialRefreshFailure: false,
            supportedActions: { _ in [] },
            activeActionIssueIDs: [],
            openSettings: { openedSettings = true },
            openIssue: { _ in },
            openSSH: { _ in },
            openRDP: { _ in },
            hasSSH: { _ in false },
            hasRDP: { _ in false },
            performRecheck: { _ in },
            requestAcknowledgement: { _ in },
            requestDowntime: { _ in }
        )
        .environment(\.locale, Locale(identifier: "de_DE"))
        .environment(\.colorScheme, .light)

        NativeViewRenderer.click(
            CGPoint(x: 694, y: 194),
            in: view,
            size: CGSize(width: 720, height: 220)
        )

        XCTAssertTrue(openedSettings)
    }

    func testCompactRowAndQuickActionsRespondToDirectPointerClicks() {
        let sourceID = UUID()
        let issue = MonitoringIssue(
            sourceID: sourceID,
            nativeID: "db-01!Disk",
            kind: .service,
            hostName: "db-01",
            serviceName: "Disk",
            displayName: "Disk",
            severity: .critical,
            summary: "CRITICAL: disk full",
            stateChangedAt: Date(timeIntervalSinceNow: -180),
            checkAttempt: 3,
            maxCheckAttempts: 4,
            isAcknowledged: false,
            isInDowntime: false
        )
        var opened = 0
        var rechecked = 0
        var acknowledged = 0
        var scheduledDowntime = 0
        let view = StatusMenuContent(
            hasConfiguredSource: true,
            hasEnabledSource: true,
            hasActiveSnapshot: true,
            actionableIssues: [issue],
            coveredIssues: [],
            sourceNames: [sourceID: "Production"],
            filters: PanelFilterSettings(
                defaults: UserDefaults(suiteName: "StatusMenuInteractionTests.\(UUID().uuidString)")!
            ),
            refreshState: .current,
            hasPartialRefreshFailure: false,
            supportedActions: { _ in [.recheck, .acknowledge, .scheduleDowntime] },
            activeActionIssueIDs: [],
            openSettings: {},
            openIssue: { _ in opened += 1 },
            openSSH: { _ in },
            openRDP: { _ in },
            hasSSH: { _ in true },
            hasRDP: { _ in true },
            performRecheck: { _ in rechecked += 1 },
            requestAcknowledgement: { _ in acknowledged += 1 },
            requestDowntime: { _ in scheduledDowntime += 1 }
        )
        .environment(\.locale, Locale(identifier: "de_DE"))
        .environment(\.colorScheme, .light)

        NativeViewRenderer.click(CGPoint(x: 300, y: 109), in: view, size: CGSize(width: 720, height: 180))
        NativeViewRenderer.click(CGPoint(x: 644, y: 109), in: view, size: CGSize(width: 720, height: 180))
        NativeViewRenderer.click(CGPoint(x: 672, y: 109), in: view, size: CGSize(width: 720, height: 180))
        NativeViewRenderer.click(CGPoint(x: 700, y: 109), in: view, size: CGSize(width: 720, height: 180))

        XCTAssertEqual(opened, 1)
        XCTAssertEqual(rechecked, 1)
        XCTAssertEqual(acknowledged, 1)
        XCTAssertEqual(scheduledDowntime, 1)
    }
}
