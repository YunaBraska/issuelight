import AppKit
import IssueLightCore
import SwiftUI
import XCTest

@MainActor
final class LandingPageScreenshotTests: XCTestCase {
    private enum PanelFixtureState {
        case noSource
        case disabledSource
        case loading
        case allClear
        case filteredEmpty
        case actionError
    }

    func testLandingPageScreenshotsRenderFromProductionViews() throws {
        let sourceData = try NativeViewRenderer.pngData(
            for: sourceSetupView,
            size: CGSize(width: 820, height: 600)
        )
        let thrukSourceData = try NativeViewRenderer.pngData(
            for: thrukSourceSetupView,
            size: CGSize(width: 820, height: 600)
        )
        let checkmkSourceData = try NativeViewRenderer.pngData(
            for: checkmkSourceSetupView,
            size: CGSize(width: 820, height: 600)
        )
        let nagiosCoreSourceData = try NativeViewRenderer.pngData(
            for: nagiosCoreSourceSetupView,
            size: CGSize(width: 820, height: 600)
        )
        let menuItemData = try NativeViewRenderer.pngData(
            for: menuItemStatesView,
            size: CGSize(width: 660, height: 180)
        )
        let germanMenuData = try NativeViewRenderer.pngData(
            for: menuPanelView(language: .german),
            size: CGSize(width: 720, height: 127)
        )
        let swedishMenuData = try NativeViewRenderer.pngData(
            for: menuPanelView(language: .swedish),
            size: CGSize(width: 720, height: 127)
        )
        let arabicMenuData = try NativeViewRenderer.pngData(
            for: menuPanelView(language: .arabic),
            size: CGSize(width: 720, height: 127)
        )
        let sourceFailureMenuData = try NativeViewRenderer.pngData(
            for: sourceFailureMenuView,
            size: CGSize(width: 720, height: 88)
        )
        let mixedProviderMenuData = try NativeViewRenderer.pngData(
            for: mixedProviderMenuView(),
            size: CGSize(width: 720, height: 205)
        )
        let noSourceMenuData = try NativeViewRenderer.pngData(
            for: menuPanelStateView(.noSource),
            size: CGSize(width: 720, height: 220)
        )
        let disabledSourceMenuData = try NativeViewRenderer.pngData(
            for: menuPanelStateView(.disabledSource),
            size: CGSize(width: 720, height: 220)
        )
        let loadingMenuData = try NativeViewRenderer.pngData(
            for: menuPanelStateView(.loading),
            size: CGSize(width: 720, height: 220)
        )
        let allClearMenuData = try NativeViewRenderer.pngData(
            for: menuPanelStateView(.allClear),
            size: CGSize(width: 720, height: 200)
        )
        let filteredEmptyMenuData = try NativeViewRenderer.pngData(
            for: menuPanelStateView(.filteredEmpty),
            size: CGSize(width: 720, height: 200)
        )
        let actionErrorMenuData = try NativeViewRenderer.pngData(
            for: menuPanelStateView(.actionError),
            size: CGSize(width: 720, height: 132)
        )
        let darkLargeTextMenuData = try NativeViewRenderer.pngData(
            for: mixedProviderMenuView(colorScheme: .dark, dynamicTypeSize: .xLarge),
            size: CGSize(width: 720, height: 225)
        )
        let mtlsPinnedSourceData = try NativeViewRenderer.pngData(
            for: sourceSecurityView(
                authentication: .clientCertificate,
                trust: .pinnedCertificate,
                expandsSSH: false
            ),
            size: CGSize(width: 900, height: 1_200)
        )
        let insecureSSHSourceData = try NativeViewRenderer.pngData(
            for: sourceSecurityView(
                authentication: .basic,
                trust: .disabled,
                expandsSSH: true
            ),
            size: CGSize(width: 900, height: 1_500)
        )
        let connectionPathData = try NativeViewRenderer.pngData(
            for: connectionPathCombinationsView,
            size: CGSize(width: 820, height: 500)
        )
        let swedishSettingsData = try NativeViewRenderer.pngData(
            for: languageSettingsView(language: .swedish),
            size: CGSize(width: 920, height: 680)
        )
        let arabicSettingsData = try NativeViewRenderer.pngData(
            for: languageSettingsView(language: .arabic),
            size: CGSize(width: 920, height: 680)
        )
        let aboutSettingsData = try NativeViewRenderer.pngData(
            for: aboutSettingsView,
            size: CGSize(width: 660, height: 470)
        )
        let notificationSettingsData = try NativeViewRenderer.pngData(
            for: notificationSettingsView,
            size: CGSize(width: 760, height: 560)
        )

        let renderedScreenshots: [(name: String, data: Data, size: CGSize)] = [
            ("Icinga source setup", sourceData, CGSize(width: 820, height: 600)),
            ("Thruk source setup", thrukSourceData, CGSize(width: 820, height: 600)),
            ("Checkmk source setup", checkmkSourceData, CGSize(width: 820, height: 600)),
            ("Nagios source setup", nagiosCoreSourceData, CGSize(width: 820, height: 600)),
            ("menu item states", menuItemData, CGSize(width: 660, height: 180)),
            ("German menu", germanMenuData, CGSize(width: 720, height: 127)),
            ("Swedish menu", swedishMenuData, CGSize(width: 720, height: 127)),
            ("Arabic menu", arabicMenuData, CGSize(width: 720, height: 127)),
            ("source failure menu", sourceFailureMenuData, CGSize(width: 720, height: 88)),
            ("mixed provider menu", mixedProviderMenuData, CGSize(width: 720, height: 205)),
            ("no source menu", noSourceMenuData, CGSize(width: 720, height: 220)),
            ("disabled source menu", disabledSourceMenuData, CGSize(width: 720, height: 220)),
            ("loading menu", loadingMenuData, CGSize(width: 720, height: 220)),
            ("all clear menu", allClearMenuData, CGSize(width: 720, height: 200)),
            ("filtered menu", filteredEmptyMenuData, CGSize(width: 720, height: 200)),
            ("action error menu", actionErrorMenuData, CGSize(width: 720, height: 132)),
            ("dark large text menu", darkLargeTextMenuData, CGSize(width: 720, height: 225)),
            ("mTLS source", mtlsPinnedSourceData, CGSize(width: 900, height: 1_200)),
            ("insecure SSH source", insecureSSHSourceData, CGSize(width: 900, height: 1_500)),
            ("connection paths", connectionPathData, CGSize(width: 820, height: 500)),
            ("Swedish settings", swedishSettingsData, CGSize(width: 920, height: 680)),
            ("Arabic settings", arabicSettingsData, CGSize(width: 920, height: 680)),
            ("About settings", aboutSettingsData, CGSize(width: 660, height: 470)),
            ("notification settings", notificationSettingsData, CGSize(width: 760, height: 560)),
        ]
        for screenshot in renderedScreenshots {
            assertValidPNG(
                screenshot.data,
                logicalSize: screenshot.size,
                name: screenshot.name
            )
        }

        guard let outputPath = ProcessInfo.processInfo.environment["ISSUELIGHT_SCREENSHOT_OUTPUT_DIR"] else {
            return
        }
        let outputDirectory = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        try sourceData.write(
            to: outputDirectory.appendingPathComponent("source-setup.png"),
            options: .atomic
        )
        try thrukSourceData.write(
            to: outputDirectory.appendingPathComponent("source-setup-thruk.png"),
            options: .atomic
        )
        try checkmkSourceData.write(
            to: outputDirectory.appendingPathComponent("source-setup-checkmk.png"),
            options: .atomic
        )
        try nagiosCoreSourceData.write(
            to: outputDirectory.appendingPathComponent("source-setup-nagios-core.png"),
            options: .atomic
        )
        try menuItemData.write(
            to: outputDirectory.appendingPathComponent("menu-item-states.png"),
            options: .atomic
        )
        try germanMenuData.write(
            to: outputDirectory.appendingPathComponent("menu-panel-de.png"),
            options: .atomic
        )
        try swedishMenuData.write(
            to: outputDirectory.appendingPathComponent("menu-panel-sv.png"),
            options: .atomic
        )
        try arabicMenuData.write(
            to: outputDirectory.appendingPathComponent("menu-panel-ar.png"),
            options: .atomic
        )
        try sourceFailureMenuData.write(
            to: outputDirectory.appendingPathComponent("menu-panel-source-failure.png"),
            options: .atomic
        )
        try mixedProviderMenuData.write(
            to: outputDirectory.appendingPathComponent("menu-panel-all-providers.png"),
            options: .atomic
        )
        try noSourceMenuData.write(
            to: outputDirectory.appendingPathComponent("menu-panel-no-source.png"),
            options: .atomic
        )
        try disabledSourceMenuData.write(
            to: outputDirectory.appendingPathComponent("menu-panel-disabled-source.png"),
            options: .atomic
        )
        try loadingMenuData.write(
            to: outputDirectory.appendingPathComponent("menu-panel-loading.png"),
            options: .atomic
        )
        try allClearMenuData.write(
            to: outputDirectory.appendingPathComponent("menu-panel-all-clear.png"),
            options: .atomic
        )
        try filteredEmptyMenuData.write(
            to: outputDirectory.appendingPathComponent("menu-panel-filtered-empty.png"),
            options: .atomic
        )
        try actionErrorMenuData.write(
            to: outputDirectory.appendingPathComponent("menu-panel-action-error.png"),
            options: .atomic
        )
        try darkLargeTextMenuData.write(
            to: outputDirectory.appendingPathComponent("menu-panel-dark-large-text.png"),
            options: .atomic
        )
        try mtlsPinnedSourceData.write(
            to: outputDirectory.appendingPathComponent("source-setup-mtls-pinned.png"),
            options: .atomic
        )
        try insecureSSHSourceData.write(
            to: outputDirectory.appendingPathComponent("source-setup-insecure-ssh.png"),
            options: .atomic
        )
        try connectionPathData.write(
            to: outputDirectory.appendingPathComponent("connection-path-combinations.png"),
            options: .atomic
        )
        try swedishSettingsData.write(
            to: outputDirectory.appendingPathComponent("language-settings-sv.png"),
            options: .atomic
        )
        try arabicSettingsData.write(
            to: outputDirectory.appendingPathComponent("language-settings-ar.png"),
            options: .atomic
        )
        try aboutSettingsData.write(
            to: outputDirectory.appendingPathComponent("settings-about.png"),
            options: .atomic
        )
        try notificationSettingsData.write(
            to: outputDirectory.appendingPathComponent("settings-notifications.png"),
            options: .atomic
        )
    }

    private func assertValidPNG(
        _ data: Data,
        logicalSize: CGSize,
        name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertGreaterThan(data.count, 1_024, "\(name) is unexpectedly empty", file: file, line: line)
        guard let bitmap = NSBitmapImageRep(data: data) else {
            XCTFail("\(name) is not a decodable image", file: file, line: line)
            return
        }
        XCTAssertGreaterThanOrEqual(
            bitmap.pixelsWide,
            Int(logicalSize.width),
            "\(name) is narrower than its requested render size",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            bitmap.pixelsHigh,
            Int(logicalSize.height),
            "\(name) is shorter than its requested render size",
            file: file,
            line: line
        )
    }

    private var sourceSetupView: some View {
        sourceSetupView(
            providerID: Icinga2Provider.id,
            name: "Production",
            endpoint: "https://icinga.example:5665",
            authentication: .basic,
            username: "monitoring-reader"
        )
    }

    private var thrukSourceSetupView: some View {
        sourceSetupView(
            providerID: ThrukProvider.id,
            name: "Operations",
            endpoint: "monitoring.example/thruk",
            authentication: .apiKey,
            username: "automation"
        )
    }

    private var checkmkSourceSetupView: some View {
        sourceSetupView(
            providerID: CheckmkProvider.id,
            name: "Platform",
            endpoint: "monitoring.example/cmk",
            authentication: .apiKey,
            username: "automation"
        )
    }

    private var nagiosCoreSourceSetupView: some View {
        sourceSetupView(
            providerID: NagiosCoreProvider.id,
            name: "Legacy",
            endpoint: "monitoring.example/nagios",
            authentication: .basic,
            username: "monitoring-reader"
        )
    }

    private func sourceSetupView(
        providerID: ProviderID,
        name: String,
        endpoint: String,
        authentication: IssueLightModel.AuthenticationChoice,
        username: String
    ) -> some View {
        let model = IssueLightModel(
            sourceStore: nil,
            providerRegistry: .builtIn(),
            passwordVault: KeychainPasswordVault(),
            identityCatalog: KeychainIdentityCatalog(),
            certificateCatalog: KeychainServerCertificateCatalog(
                ownershipScope: "berlin.yuna.issuelight.screenshot-tests"
            ),
            startsAutomatically: false
        )
        model.beginAddingSource()
        model.selectedProviderID = providerID
        model.name = name
        model.endpoint = endpoint
        model.username = username
        model.authenticationChoice = authentication
        model.serverTrustChoice = .system
        return SourceSetupView(model: model)
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.colorScheme, .light)
    }

    private var menuItemStatesView: some View {
        VStack(spacing: 12) {
            HStack(spacing: 18) {
                menuItem(title: "Set up", count: 0)
                Divider()
                menuItem(title: "Paused", count: 0)
                Divider()
                menuItem(title: "Refreshing", count: 0)
            }
            Divider()
            HStack(spacing: 18) {
                menuItem(title: "All clear", count: 0)
                Divider()
                menuItem(title: "Connection failed", count: 0)
                Divider()
                menuItem(title: "7 problems", count: 7)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.bar)
        .environment(\.colorScheme, .light)
    }

    private func menuItem(title: String, count: Int) -> some View {
        VStack(spacing: 6) {
            StatusMenuLabel(
                counts: MenuBarIssueCounts(
                    issues: (0..<count).map { index in
                        issue(
                            sourceID: UUID(),
                            id: "menu-\(index)",
                            host: "host",
                            service: index < 5 ? "Health" : nil,
                            name: index < 5 ? "Health" : "host",
                            severity: [.critical, .critical, .warning, .warning, .unknown, .critical, .critical][index],
                            summary: "fixture"
                        )
                    }
                ),
                accessibilityText: title
            )
                .font(.system(size: 14))
            Text(verbatim: title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func menuPanelView(language: AppLanguage) -> some View {
        let settings = AppLanguageSettings(selection: language)
        let productionID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let issues = [
            issue(
                sourceID: productionID,
                id: "api-database",
                host: "api-01",
                service: "PostgreSQL replication primary",
                name: "PostgreSQL replication primary",
                severity: .critical,
                summary: "CRITICAL: replication delay is 184 seconds"
            ),
            issue(
                sourceID: productionID,
                id: "storage",
                host: "nas",
                service: "Storage",
                name: "Storage",
                severity: .warning,
                summary: "WARNING: volume is 82% full"
            ),
        ]
        return VStack(alignment: .leading, spacing: 0) {
            StatusMenuContent(
                hasConfiguredSource: true,
                hasEnabledSource: true,
                hasActiveSnapshot: true,
                actionableIssues: issues,
                coveredIssues: [],
                sourceNames: [productionID: "Production"],
                sourceFailures: [],
                filters: filterSettings(),
                refreshState: .current,
                actionError: nil,
                supportedActions: { _ in [.recheck, .acknowledge, .scheduleDowntime] },
                activeActionIssueIDs: [],
                openSettings: {},
                quitApplication: {},
                openIssue: { _ in },
                openSSH: { _ in },
                openRDP: { _ in },
                hasSSH: { _ in true },
                hasRDP: { _ in true },
                performRecheck: { _ in },
                requestAcknowledgement: { _ in },
                requestDowntime: { _ in },
                dismissActionError: {}
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial)
        .appLanguageEnvironment(settings)
        .environment(\.colorScheme, .light)
    }

    private func filterSettings() -> PanelFilterSettings {
        let defaults = UserDefaults(suiteName: "LandingPageScreenshotTests.\(UUID().uuidString)")!
        return PanelFilterSettings(defaults: defaults)
    }

    private var sourceFailureMenuView: some View {
        let source = MonitoringSource(
            name: "Production",
            providerID: Icinga2Provider.id,
            endpoint: URL(string: "https://icinga.internal:5665")!,
            authentication: .basic(username: "monitoring")
        )
        return StatusMenuContent(
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
            filters: filterSettings(),
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
    }

    private func mixedProviderMenuView(
        colorScheme: ColorScheme = .light,
        dynamicTypeSize: DynamicTypeSize = .large
    ) -> some View {
        let icingaID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let thrukID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
        let checkmkID = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
        let nagiosID = UUID(uuidString: "dddddddd-dddd-4ddd-8ddd-dddddddddddd")!
        let issues = [
            issue(
                sourceID: icingaID,
                id: "icinga-db",
                host: "db-01",
                service: "Replication",
                name: "Replication",
                severity: .critical,
                summary: "CRITICAL: primary is 184 seconds behind"
            ),
            issue(
                sourceID: checkmkID,
                id: "checkmk-edge",
                host: "edge-01",
                service: nil,
                name: "edge-01",
                severity: .critical,
                summary: "DOWN: host is not reachable"
            ),
            issue(
                sourceID: thrukID,
                id: "thruk-storage",
                host: "nas-01",
                service: "Storage",
                name: "Storage",
                severity: .warning,
                summary: "WARNING: volume is 82% full"
            ),
            issue(
                sourceID: nagiosID,
                id: "nagios-dns",
                host: "legacy-01",
                service: "DNS",
                name: "DNS",
                severity: .unknown,
                summary: "UNKNOWN: resolver returned no answer"
            ),
        ]
        return StatusMenuContent(
            hasConfiguredSource: true,
            hasEnabledSource: true,
            hasActiveSnapshot: true,
            actionableIssues: issues,
            coveredIssues: [],
            sourceNames: [
                icingaID: "Icinga",
                thrukID: "Thruk",
                checkmkID: "Checkmk",
                nagiosID: "Nagios",
            ],
            sourceFailures: [],
            filters: filterSettings(),
            refreshState: .current,
            actionError: nil,
            supportedActions: { issue in
                issue.sourceID == checkmkID
                    ? [.acknowledge, .scheduleDowntime]
                    : [.recheck, .acknowledge, .scheduleDowntime]
            },
            activeActionIssueIDs: [],
            openSettings: {},
            quitApplication: {},
            openIssue: { _ in },
            openSSH: { _ in },
            openRDP: { _ in },
            hasSSH: { $0.sourceID == icingaID },
            hasRDP: { $0.sourceID == checkmkID },
            performRecheck: { _ in },
            requestAcknowledgement: { _ in },
            requestDowntime: { _ in },
            dismissActionError: {}
        )
        .background(.regularMaterial)
        .environment(\.locale, Locale(identifier: "en_US"))
        .environment(\.colorScheme, colorScheme)
        .environment(\.dynamicTypeSize, dynamicTypeSize)
    }

    private func menuPanelStateView(_ state: PanelFixtureState) -> some View {
        let sourceID = UUID(uuidString: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")!
        let sourceNames = [sourceID: "Production"]
        let problem = issue(
            sourceID: sourceID,
            id: "state-problem",
            host: "api-01",
            service: "Health",
            name: "Health",
            severity: .critical,
            summary: "CRITICAL: upstream is unavailable"
        )
        let filters = filterSettings()

        let hasConfiguredSource: Bool
        let hasEnabledSource: Bool
        let hasActiveSnapshot: Bool
        let issues: [MonitoringIssue]
        let refreshState: IssueLightModel.RefreshState
        let actionError: String?

        switch state {
        case .noSource:
            hasConfiguredSource = false
            hasEnabledSource = false
            hasActiveSnapshot = false
            issues = []
            refreshState = .notConfigured
            actionError = nil
        case .disabledSource:
            hasConfiguredSource = true
            hasEnabledSource = false
            hasActiveSnapshot = false
            issues = []
            refreshState = .notConfigured
            actionError = nil
        case .loading:
            hasConfiguredSource = true
            hasEnabledSource = true
            hasActiveSnapshot = false
            issues = []
            refreshState = .refreshing
            actionError = nil
        case .allClear:
            hasConfiguredSource = true
            hasEnabledSource = true
            hasActiveSnapshot = true
            issues = []
            refreshState = .current
            actionError = nil
        case .filteredEmpty:
            hasConfiguredSource = true
            hasEnabledSource = true
            hasActiveSnapshot = true
            issues = [problem]
            filters.setHost(
                PanelHostSelection(issue: problem),
                excluded: true
            )
            refreshState = .current
            actionError = nil
        case .actionError:
            hasConfiguredSource = true
            hasEnabledSource = true
            hasActiveSnapshot = true
            issues = [problem]
            refreshState = .current
            actionError = "Acknowledgement failed. The server rejected the request."
        }

        return StatusMenuContent(
            hasConfiguredSource: hasConfiguredSource,
            hasEnabledSource: hasEnabledSource,
            hasActiveSnapshot: hasActiveSnapshot,
            actionableIssues: issues,
            coveredIssues: [],
            sourceNames: sourceNames,
            sourceFailures: [],
            filters: filters,
            refreshState: refreshState,
            actionError: actionError,
            supportedActions: { _ in [.recheck, .acknowledge, .scheduleDowntime] },
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
        .environment(\.locale, Locale(identifier: "en_US"))
        .environment(\.colorScheme, .light)
    }

    private func languageSettingsView(language: AppLanguage) -> some View {
        let settings = AppLanguageSettings(selection: language)
        return IssueLightSettingsView(
            model: screenshotModel,
            languageSettings: settings,
            notificationCoordinator: screenshotNotificationCoordinator(locale: settings.locale),
            updateController: AppUpdateController(),
            initialSelection: .language
        )
            .appLanguageEnvironment(settings)
            .environment(\.colorScheme, .light)
    }

    private var notificationSettingsView: some View {
        let productionID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let homelabID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        let sources = [
            MonitoringSource(
                id: productionID,
                name: "Production",
                providerID: Icinga2Provider.id,
                endpoint: URL(string: "https://icinga.example:5665")!,
                authentication: .basic(username: "monitoring")
            ),
            MonitoringSource(
                id: homelabID,
                name: "Homelab",
                providerID: ThrukProvider.id,
                endpoint: URL(string: "https://monitoring.example/thruk/r/v1")!,
                isEnabled: false,
                authentication: .apiKey(username: "")
            ),
        ]
        return NotificationSettingsContent(
            sources: sources,
            authorization: .authorized,
            policy: { sourceID in
                sourceID == productionID ? .criticalOnly : .allAttentionStates
            },
            setPolicy: { _, _ in },
            requestAuthorization: {}
        )
        .frame(width: 728, height: 528)
        .environment(\.locale, Locale(identifier: "de"))
        .environment(\.colorScheme, .light)
    }

    private func screenshotNotificationCoordinator(locale: Locale) -> IssueNotificationCoordinator {
        let defaults = UserDefaults(
            suiteName: "LandingPageScreenshotNotifications.\(UUID().uuidString)"
        )!
        return IssueNotificationCoordinator(
            policyStore: IssueNotificationPolicyStore(defaults: defaults),
            notificationCenter: ScreenshotNotificationCenterClient(),
            locale: locale
        )
    }

    private func sourceSecurityView(
        authentication: IssueLightModel.AuthenticationChoice,
        trust: IssueLightModel.ServerTrustChoice,
        expandsSSH: Bool
    ) -> some View {
        let model = screenshotModel
        model.beginAddingSource()
        model.name = expandsSSH ? "Homelab" : "Production"
        model.endpoint = expandsSSH
            ? "monitoring.internal:5665"
            : "https://icinga.example:5665"
        model.authenticationChoice = authentication
        model.username = "monitoring"
        model.serverTrustChoice = trust
        if expandsSSH {
            model.sshTunnelHost = "bastion.internal"
            model.sshTunnelUsername = "operator"
            model.sshTunnelPort = "2222"
            model.sshTunnelPreferredLocalPort = "5665"
            model.sshActionEnabled = true
            model.sshUsername = "operator"
            model.rdpActionEnabled = true
            model.rdpUsername = "administrator"
        }
        return SourceSetupView(
            model: model,
            initiallyShowsSSHOverrides: expandsSSH
        )
        .environment(\.locale, Locale(identifier: "de_DE"))
        .environment(\.colorScheme, .light)
    }

    private var connectionPathCombinationsView: some View {
        let combinations: [(String, IssueLightModel.ConnectionEndpointState, IssueLightModel.ConnectionEndpointState)] = [
            ("Both direct", .direct, .direct),
            ("API through SSH", .ssh, .direct),
            ("Web through SSH", .direct, .ssh),
            ("Web unavailable", .direct, .failed("Web interface is unreachable")),
            ("API unavailable", .failed("API is unreachable"), .direct),
            ("Both unavailable", .failed("API is unreachable"), .failed("Web interface is unreachable")),
        ]
        let columns = [GridItem(.flexible()), GridItem(.flexible())]
        return VStack(alignment: .leading, spacing: 18) {
            Text(verbatim: "API and web reachability")
                .font(.title2.weight(.semibold))
            Text(verbatim: "IssueLight tests both endpoints independently and reports the selected route.")
                .foregroundStyle(.secondary)
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(Array(combinations.enumerated()), id: \.offset) { _, combination in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(verbatim: combination.0)
                            .font(.headline)
                        Divider()
                        LabeledContent("API") {
                            ConnectionEndpointStatusView(state: combination.1)
                        }
                        LabeledContent("Web") {
                            ConnectionEndpointStatusView(state: combination.2)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                }
            }
        }
        .padding(22)
        .environment(\.locale, Locale(identifier: "en_US"))
        .environment(\.colorScheme, .light)
    }

    private var screenshotModel: IssueLightModel {
        IssueLightModel(
            sourceStore: nil,
            providerRegistry: .builtIn(),
            passwordVault: KeychainPasswordVault(),
            identityCatalog: KeychainIdentityCatalog(),
            certificateCatalog: KeychainServerCertificateCatalog(
                ownershipScope: "berlin.yuna.issuelight.screenshot-tests"
            ),
            startsAutomatically: false
        )
    }

    private var aboutSettingsView: some View {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Assets.xcassets/AppIcon.appiconset/IssueLight-256.png")
        return AboutSettingsView(
            icon: NSImage(contentsOf: resources)!,
            version: "0.1.0",
            build: "1",
            copyrightText: "Copyright © 2026 Yuna Morgenstern and IssueLight contributors.",
            updateController: AppUpdateController(),
            messageIndex: 0
        )
        .frame(width: 620, height: 430)
        .environment(\.locale, Locale(identifier: "de"))
        .environment(\.colorScheme, .light)
    }

    private func issue(
        sourceID: UUID,
        id: String,
        host: String,
        service: String?,
        name: String,
        severity: MonitoringSeverity,
        summary: String
    ) -> MonitoringIssue {
        MonitoringIssue(
            sourceID: sourceID,
            nativeID: id,
            kind: service == nil ? .host : .service,
            hostName: host,
            serviceName: service,
            displayName: name,
            severity: severity,
            summary: summary,
            stateChangedAt: Date.now.addingTimeInterval(-7_384),
            checkAttempt: severity == .warning ? 2 : 4,
            maxCheckAttempts: severity == .warning ? 3 : 4,
            isAcknowledged: false,
            isInDowntime: false
        )
    }

}

@MainActor
private final class ScreenshotNotificationCenterClient: IssueNotificationCenterClient {
    func setResponseHandler(_: @escaping @MainActor (String) -> Void) {}
    func currentAuthorization() async -> IssueNotificationAuthorization { .authorized }
    func requestAuthorization() async -> IssueNotificationAuthorization { .authorized }
    func deliver(_: IssueNotificationContent) async throws {}
    func remove(identifier _: String) {}
    func removeAll() {}
}
