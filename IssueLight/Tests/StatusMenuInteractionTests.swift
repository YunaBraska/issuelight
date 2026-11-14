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
            actionError: nil,
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
            requestDowntime: { _ in },
            dismissActionError: {}
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

    func testCompactPanelUsesOnlyContentHeightAndQuickActionsRespondToDirectPointerClicks() {
        let sourceID = UUID()
        let issue = MonitoringIssue(
            sourceID: sourceID,
            nativeID: "db-01!Disk",
            kind: .service,
            hostName: "db-01",
            serviceName: "Disk",
            displayName: "Disk",
            severity: .critical,
            summary: "CRITICAL: the replication queue has exceeded its safe operating threshold for twelve minutes",
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
            actionError: nil,
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
            requestDowntime: { _ in scheduledDowntime += 1 },
            dismissActionError: {}
        )
        .environment(\.locale, Locale(identifier: "de_DE"))
        .environment(\.colorScheme, .light)

        let fittedSize = NativeViewRenderer.fittingSize(
            for: view,
            maximumSize: CGSize(width: 720, height: 520)
        )
        let largerTextSize = NativeViewRenderer.fittingSize(
            for: view.environment(\.dynamicTypeSize, .accessibility1),
            maximumSize: CGSize(width: 720, height: 520)
        )
        NativeViewRenderer.click(CGPoint(x: 300, y: 19), in: view, size: fittedSize)
        NativeViewRenderer.click(CGPoint(x: 644, y: 19), in: view, size: fittedSize)
        NativeViewRenderer.click(CGPoint(x: 672, y: 19), in: view, size: fittedSize)
        NativeViewRenderer.click(CGPoint(x: 700, y: 19), in: view, size: fittedSize)

        XCTAssertEqual(fittedSize.height, 88, accuracy: 1)
        XCTAssertGreaterThan(largerTextSize.height, fittedSize.height)
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(rechecked, 1)
        XCTAssertEqual(acknowledged, 1)
        XCTAssertEqual(scheduledDowntime, 1)
    }

    func testActionErrorCanBeDismissedWithoutAWindowModal() {
        var dismissed = false
        let view = StatusActionErrorBanner(
            message: "Icinga rejected the action.",
            dismiss: { dismissed = true }
        )
        .environment(\.colorScheme, .light)

        NativeViewRenderer.click(
            CGPoint(x: 389, y: 25),
            in: view,
            size: CGSize(width: 400, height: 50)
        )

        XCTAssertTrue(dismissed)
    }

    func testSourceAddButtonRespondsToPointerClick() {
        var added = false
        let view = SourceSidebarFooter(addSource: { added = true })
            .environment(\.locale, Locale(identifier: "de_DE"))
            .environment(\.colorScheme, .light)

        NativeViewRenderer.click(
            CGPoint(x: 75, y: 21),
            in: view,
            size: CGSize(width: 250, height: 42)
        )

        XCTAssertTrue(added)
    }

    func testActionFieldsKeepEnoughIntrinsicHeightInsideMenuPanelSheet() {
        let acknowledgement = IssueActionInputFields(
            author: .constant("Operator"),
            comment: .constant("Investigating"),
            duration: .constant(3_600),
            includesDuration: false
        )
        .environment(\.locale, Locale(identifier: "de_DE"))
        let downtime = IssueActionInputFields(
            author: .constant("Operator"),
            comment: .constant("Maintenance"),
            duration: .constant(3_600),
            includesDuration: true
        )
        .environment(\.locale, Locale(identifier: "de_DE"))

        let acknowledgementSize = NativeViewRenderer.fittingSize(
            for: acknowledgement,
            maximumSize: CGSize(width: 436, height: 400)
        )
        let downtimeSize = NativeViewRenderer.fittingSize(
            for: downtime,
            maximumSize: CGSize(width: 436, height: 400)
        )

        XCTAssertGreaterThanOrEqual(acknowledgementSize.height, 70)
        XCTAssertGreaterThan(downtimeSize.height, acknowledgementSize.height)
    }
}
