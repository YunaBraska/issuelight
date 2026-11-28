import AppKit
import IssueLightCore
import SwiftUI
import XCTest

@MainActor
final class StatusMenuInteractionTests: XCTestCase {
    func testMenuBarLighthouseUsesVisibleNativeTemplateImage() throws {
        let image = try XCTUnwrap(
            IssueLightResources.bundle
                .image(forResource: NSImage.Name("MenuBarLighthouse"))
        )

        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
    }

    func testMenuBarShowsLighthouseOnlyWhenThereAreNoIssueCounts() {
        let issue = MonitoringIssue(
            sourceID: UUID(),
            nativeID: "critical-service",
            kind: .service,
            hostName: "api-01",
            serviceName: "Health",
            displayName: "Health",
            severity: .critical,
            summary: "Unavailable",
            isAcknowledged: false,
            isInDowntime: false
        )
        let counts = MenuBarIssueCounts(issues: [issue])
        let maximumSize = CGSize(width: 200, height: 40)
        let labelSize = NativeViewRenderer.fittingSize(
            for: StatusMenuLabel(
                counts: counts,
                accessibilityText: "One critical issue"
            )
            .font(.system(size: 14)),
            maximumSize: maximumSize
        )
        let countOnlySize = NativeViewRenderer.fittingSize(
            for: Text(verbatim: counts.compactText)
                .monospacedDigit()
                .font(.system(size: 14)),
            maximumSize: maximumSize
        )
        let emptySize = NativeViewRenderer.fittingSize(
            for: StatusMenuLabel(
                counts: MenuBarIssueCounts(issues: []),
                accessibilityText: "All clear"
            )
            .font(.system(size: 14)),
            maximumSize: maximumSize
        )

        XCTAssertEqual(labelSize.width, countOnlySize.width, accuracy: 0.5)
        XCTAssertEqual(labelSize.height, countOnlySize.height, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(emptySize.width, 17)
        XCTAssertGreaterThanOrEqual(emptySize.height, 17)
    }

    func testSSHSettingsDisclosureRespondsAcrossTheEntireRow() {
        var isExpanded = false
        let view = SSHSettingsDisclosureRow(
            isExpanded: Binding(
                get: { isExpanded },
                set: { isExpanded = $0 }
            )
        )
        .environment(\.locale, Locale(identifier: "de_DE"))
        .environment(\.colorScheme, .light)

        NativeViewRenderer.click(
            CGPoint(x: 496, y: 14),
            in: view,
            size: CGSize(width: 500, height: 28)
        )

        XCTAssertTrue(isExpanded)
    }

    func testSSHTunnelSettingsRenderAutomaticDefaultsAtCompactWidth() throws {
        let view = Form {
            SSHTunnelSettingsView(
                host: .constant(""),
                username: .constant(""),
                port: .constant(""),
                identityFilePath: .constant(""),
                preferredLocalPort: .constant(""),
                automaticHost: "monitoring.internal",
                chooseIdentity: {}
            )
        }
        .formStyle(.grouped)
        .environment(\.locale, Locale(identifier: "de_DE"))
        .environment(\.colorScheme, .light)

        let size = CGSize(width: 500, height: 260)
        XCTAssertTrue(NativeViewRenderer.exerciseWindow(for: view, size: size))
        XCTAssertTrue(
            NativeViewRenderer.exerciseWindow(
                for: view.environment(\.dynamicTypeSize, .accessibility1),
                size: CGSize(width: 500, height: 360)
            )
        )
        if let outputPath = ProcessInfo.processInfo.environment[
            "ISSUELIGHT_SSH_SETTINGS_SCREENSHOT_PATH"
        ] {
            let pngData = try NativeViewRenderer.pngData(for: view, size: size)
            XCTAssertGreaterThan(pngData.count, 10_000)
            try pngData.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        }
        if let outputPath = ProcessInfo.processInfo.environment[
            "ISSUELIGHT_SSH_SETTINGS_LARGE_TEXT_SCREENSHOT_PATH"
        ] {
            let pngData = try NativeViewRenderer.pngData(
                for: view.environment(\.dynamicTypeSize, .accessibility1),
                size: CGSize(width: 500, height: 360)
            )
            XCTAssertGreaterThan(pngData.count, 10_000)
            try pngData.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        }
    }

    func testSourceFilterEditorRendersExistingRulesInANativeWindow() throws {
        var source = MonitoringSource(
            name: "Infrastructure",
            providerID: Icinga2Provider.id,
            endpoint: URL(string: "https://monitoring.example.test")!,
            authentication: .basic(username: "operator")
        )
        var filter = SourceIssueFilter()
        filter.hostConditions.insert(.downtime)
        filter.serviceConditions.insert(.acknowledged)
        filter.patterns = [
            .init(service: "apt", states: [.warning, .pending, .unknown, .critical]),
            .init(service: "qnap-*", states: [.warning, .pending, .unknown, .critical]),
            .init(host: "edge-*", states: [.down, .unreachable]),
        ]
        source.issueFilter = filter
        let sourceID = source.id
        let issues = [("db-01", "apt"), ("db-02", "apt"), ("nas-01", "qnap-backup"), ("db-01", "HTTP")]
            .map { host, service in
                MonitoringIssue(
                    sourceID: sourceID, nativeID: "\(host)!\(service)", kind: .service,
                    hostName: host, serviceName: service, displayName: service, severity: .critical,
                    summary: "Critical", isAcknowledged: false, isInDowntime: false
                )
            }
        var savedFilter: SourceIssueFilter?
        let view = SourceIssueFilterEditor(source: source, issues: issues) { settings in
            savedFilter = settings
            return true
        }
        .environment(\.locale, Locale(identifier: "de"))
        .environment(\.colorScheme, .light)
        let size = CGSize(width: 620, height: 590)
        XCTAssertTrue(NativeViewRenderer.exerciseWindow(for: view, size: size))
        let screenshot = try NativeViewRenderer.pngData(for: view, size: size)
        XCTAssertGreaterThan(screenshot.count, 10_000)
        if let path = ProcessInfo.processInfo.environment["ISSUELIGHT_SOURCE_FILTER_SCREENSHOT_PATH"] {
            try screenshot.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        NativeViewRenderer.click(
            [
                CGPoint(x: 38, y: 436), CGPoint(x: 338, y: 390), CGPoint(x: 38, y: 305),
                CGPoint(x: 387, y: 556), CGPoint(x: 573, y: 125), CGPoint(x: 565, y: 28),
            ],
            in: view,
            size: size
        )
        XCTAssertEqual(savedFilter?.hostConditions, [])
        XCTAssertEqual(savedFilter?.serviceConditions, [.acknowledged, .flapping])
        XCTAssertEqual(savedFilter?.hideServicesOfHostsInDowntime, true)
        XCTAssertEqual(savedFilter?.showPendingChecks, true)
        XCTAssertEqual(savedFilter?.patterns, Array(filter.patterns.prefix(2)))
    }

    func testPortNumberFormatNeverAddsLocaleGrouping() {
        XCTAssertEqual(
            PortNumberField.format.locale(Locale(identifier: "de_DE")).format(3_389),
            "3389"
        )
        XCTAssertEqual(
            PortNumberField.format.locale(Locale(identifier: "sv_SE")).format(22_222),
            "22222"
        )
    }

    func testSettingsWindowConfigurationRestoresNativeResizeBehavior() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 648),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let configurationView = SettingsWindowConfigurationView()
        window.contentView = configurationView

        window.styleMask.remove(.resizable)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))

        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertEqual(window.contentMinSize, NSSize(width: 760, height: 560))
        XCTAssertEqual(window.contentMaxSize.width, CGFloat.greatestFiniteMagnitude)
        XCTAssertEqual(window.contentMaxSize.height, CGFloat.greatestFiniteMagnitude)
    }

    func testSettingsButtonRespondsToPointerClick() {
        var openedSettings = false
        let view = StatusMenuContent(
            hasConfiguredSource: false,
            hasEnabledSource: false,
            hasActiveSnapshot: false,
            actionableIssues: [],
            coveredIssues: [],
            sourceNames: [:],
            sourceFailures: [],
            filters: PanelFilterSettings(
                defaults: UserDefaults(suiteName: "StatusMenuInteractionTests.\(UUID().uuidString)")!
            ),
            refreshState: .notConfigured,
            actionError: nil,
            supportedActions: { _ in [] },
            activeActionIssueIDs: [],
            openSettings: { openedSettings = true },
            quitApplication: {},
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
            CGPoint(x: 657, y: 194),
            in: view,
            size: CGSize(width: 720, height: 220)
        )

        XCTAssertTrue(openedSettings)
    }

    func testQuitButtonRespondsToPointerClick() {
        var quitApplication = false
        let view = StatusMenuContent(
            hasConfiguredSource: false,
            hasEnabledSource: false,
            hasActiveSnapshot: false,
            actionableIssues: [],
            coveredIssues: [],
            sourceNames: [:],
            sourceFailures: [],
            filters: PanelFilterSettings(
                defaults: UserDefaults(suiteName: "StatusMenuInteractionTests.\(UUID().uuidString)")!
            ),
            refreshState: .notConfigured,
            actionError: nil,
            supportedActions: { _ in [] },
            activeActionIssueIDs: [],
            openSettings: {},
            quitApplication: { quitApplication = true },
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

        XCTAssertTrue(quitApplication)
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
            sourceFailures: [],
            filters: PanelFilterSettings(
                defaults: UserDefaults(suiteName: "StatusMenuInteractionTests.\(UUID().uuidString)")!
            ),
            refreshState: .current,
            actionError: nil,
            supportedActions: { _ in [.recheck, .acknowledge, .scheduleDowntime] },
            activeActionIssueIDs: [],
            openSettings: {},
            quitApplication: {},
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

    func testHostExclusionFiltersPanelRowsAndMenuBarCountsTogether() {
        let sourceID = UUID()
        let hiddenIssue = MonitoringIssue(
            sourceID: sourceID,
            nativeID: "api-01!Health",
            kind: .service,
            hostName: "api-01",
            serviceName: "Health",
            displayName: "Health",
            severity: .critical,
            summary: "CRITICAL: unavailable",
            isAcknowledged: false,
            isInDowntime: false
        )
        let selectedIssue = MonitoringIssue(
            sourceID: sourceID,
            nativeID: "database-01!Replication",
            kind: .service,
            hostName: "database-01",
            serviceName: "Replication",
            displayName: "Replication",
            severity: .warning,
            summary: "WARNING: delayed",
            isAcknowledged: false,
            isInDowntime: false
        )
        let suiteName = "StatusMenuHostFilterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let filters = PanelFilterSettings(defaults: defaults)
        filters.setHost(PanelHostSelection(issue: hiddenIssue), excluded: true)
        var openedIssueID: String?
        let view = StatusMenuContent(
            hasConfiguredSource: true,
            hasEnabledSource: true,
            hasActiveSnapshot: true,
            actionableIssues: [hiddenIssue, selectedIssue],
            coveredIssues: [],
            sourceNames: [sourceID: "Production"],
            sourceFailures: [],
            filters: filters,
            refreshState: .current,
            actionError: nil,
            supportedActions: { _ in [] },
            activeActionIssueIDs: [],
            openSettings: {},
            quitApplication: {},
            openIssue: { openedIssueID = $0.id },
            openSSH: { _ in },
            openRDP: { _ in },
            hasSSH: { _ in false },
            hasRDP: { _ in false },
            performRecheck: { _ in },
            requestAcknowledgement: { _ in },
            requestDowntime: { _ in },
            dismissActionError: {}
        )
        .environment(\.locale, Locale(identifier: "en_US"))
        .environment(\.colorScheme, .light)

        let fittedSize = NativeViewRenderer.fittingSize(
            for: view,
            maximumSize: CGSize(width: 720, height: 520)
        )
        NativeViewRenderer.click(CGPoint(x: 300, y: 19), in: view, size: fittedSize)
        let visibleMenuIssues = [hiddenIssue, selectedIssue].filter(filters.includesHost)

        XCTAssertEqual(fittedSize.height, 88, accuracy: 1)
        XCTAssertEqual(openedIssueID, selectedIssue.id)
        XCTAssertEqual(MenuBarIssueCounts(issues: visibleMenuIssues).compactText, "W:1")
    }

    func testFailedSourceRendersAsCompactPanelRowWithoutSnapshot() {
        let source = MonitoringSource(
            name: "Production",
            providerID: Icinga2Provider.id,
            endpoint: URL(string: "https://icinga.internal:5665")!,
            authentication: .basic(username: "monitoring")
        )
        let view = StatusMenuContent(
            hasConfiguredSource: true,
            hasEnabledSource: true,
            hasActiveSnapshot: false,
            actionableIssues: [],
            coveredIssues: [],
            sourceNames: [source.id: source.name],
            sourceFailures: [
                IssueLightModel.SourceFailure(
                    source: source,
                    message: "Der Server ist nicht erreichbar."
                )
            ],
            filters: PanelFilterSettings(
                defaults: UserDefaults(suiteName: "StatusMenuInteractionTests.\(UUID().uuidString)")!
            ),
            refreshState: .failed("Production: Der Server ist nicht erreichbar."),
            actionError: nil,
            supportedActions: { _ in [] },
            activeActionIssueIDs: [],
            openSettings: {},
            quitApplication: {},
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

        let fittedSize = NativeViewRenderer.fittingSize(
            for: view,
            maximumSize: CGSize(width: 720, height: 520)
        )

        XCTAssertEqual(fittedSize.height, 88, accuracy: 1)
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

    func testNewSourceDraftHasAVisibleCompactSidebarRow() {
        let view = SourceDraftRow(name: "Production Icinga", providerName: "Icinga 2")
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.colorScheme, .light)
        let size = NativeViewRenderer.fittingSize(
            for: view,
            maximumSize: CGSize(width: 250, height: 80)
        )

        XCTAssertGreaterThanOrEqual(size.height, 32)
        XCTAssertLessThan(size.height, 60)
        XCTAssertTrue(
            NativeViewRenderer.exerciseWindow(
                for: view,
                size: CGSize(width: 250, height: ceil(size.height))
            )
        )
    }

    func testOpaqueConfirmationRendersAtReadableSize() {
        let view = OpaqueConfirmationView(
            title: "Remove source?",
            message: "The saved source and its IssueLight credentials will be removed.",
            confirmTitle: "Remove source",
            cancelTitle: "Cancel",
            confirm: {},
            cancel: {}
        )
        .environment(\.locale, Locale(identifier: "en_US"))
        .environment(\.colorScheme, .light)
        let size = NativeViewRenderer.fittingSize(
            for: view,
            maximumSize: CGSize(width: 500, height: 300)
        )

        XCTAssertEqual(size.width, 440, accuracy: 1)
        XCTAssertGreaterThan(size.height, 120)
        XCTAssertLessThan(size.height, 300)
        XCTAssertTrue(NativeViewRenderer.exerciseWindow(for: view, size: size))
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
