import IssueLightCore
import SwiftUI
import XCTest

@MainActor
final class StatusMenuInteractionTests: XCTestCase {
    func testSettingsButtonRespondsToPointerClick() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["CI"] == "true",
            "Pointer interaction requires an active macOS WindowServer."
        )
        var openedSettings = false
        let view = StatusMenuContent(
            hasConfiguredSource: false,
            hasEnabledSource: false,
            hasActiveSnapshot: false,
            actionableIssues: [],
            coveredIssues: [],
            sourceNames: [:],
            refreshState: .notConfigured,
            hasPartialRefreshFailure: false,
            supportedActions: { _ in [] },
            activeActionIssueIDs: [],
            openSettings: { openedSettings = true },
            performRecheck: { _ in },
            requestAcknowledgement: { _ in },
            requestDowntime: { _ in }
        )
        .environment(\.locale, Locale(identifier: "de_DE"))
        .environment(\.colorScheme, .light)

        NativeViewRenderer.click(
            CGPoint(x: 404, y: 234),
            in: view,
            size: CGSize(width: 430, height: 260)
        )

        XCTAssertTrue(openedSettings)
    }
}
