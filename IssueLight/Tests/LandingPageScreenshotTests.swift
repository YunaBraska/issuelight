import AppKit
import IssueLightCore
import SwiftUI
import XCTest

@MainActor
final class LandingPageScreenshotTests: XCTestCase {
    func testLandingPageScreenshotsRenderFromProductionViews() throws {
        let sourceData = try NativeViewRenderer.pngData(
            for: sourceSetupView,
            size: CGSize(width: 820, height: 600)
        )
        let menuItemData = try NativeViewRenderer.pngData(
            for: menuItemStatesView,
            size: CGSize(width: 540, height: 92)
        )
        let germanMenuData = try NativeViewRenderer.pngData(
            for: menuPanelView(language: .german),
            size: CGSize(width: 720, height: 180)
        )
        let swedishMenuData = try NativeViewRenderer.pngData(
            for: menuPanelView(language: .swedish),
            size: CGSize(width: 720, height: 180)
        )
        let arabicMenuData = try NativeViewRenderer.pngData(
            for: menuPanelView(language: .arabic),
            size: CGSize(width: 720, height: 180)
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

        XCTAssertGreaterThan(sourceData.count, 50_000)
        XCTAssertGreaterThan(menuItemData.count, 4_000)
        XCTAssertGreaterThan(germanMenuData.count, 10_000)
        XCTAssertGreaterThan(swedishMenuData.count, 10_000)
        XCTAssertGreaterThan(arabicMenuData.count, 10_000)
        XCTAssertGreaterThan(swedishSettingsData.count, 8_000)
        XCTAssertGreaterThan(arabicSettingsData.count, 8_000)
        XCTAssertGreaterThan(aboutSettingsData.count, 20_000)

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
    }

    private var sourceSetupView: some View {
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
        model.name = "Produktion"
        model.endpoint = "https://icinga.example:5665"
        model.username = "monitoring-reader"
        model.authenticationChoice = .basic
        model.serverTrustChoice = .system
        return SourceSetupView(model: model)
            .environment(\.locale, Locale(identifier: "de_DE"))
            .environment(\.colorScheme, .light)
    }

    private var menuItemStatesView: some View {
        HStack(spacing: 26) {
            menuItem(
                title: "Noch nicht eingerichtet",
                symbol: "exclamationmark.triangle",
                count: 0
            )
            Divider()
            menuItem(title: "Alles ruhig", symbol: "checkmark.circle", count: 0)
            Divider()
            menuItem(title: "Aufmerksamkeit", symbol: "exclamationmark.octagon.fill", count: 7)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.bar)
        .environment(\.colorScheme, .light)
    }

    private func menuItem(title: String, symbol: String, count: Int) -> some View {
        VStack(spacing: 6) {
            StatusMenuLabel(
                symbol: symbol,
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
    }

    private func menuPanelView(language: AppLanguage) -> some View {
        let settings = AppLanguageSettings(selection: language)
        let productionID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let issues = [
            issue(
                sourceID: productionID,
                id: "api-database",
                host: "api-01",
                service: "PostgreSQL",
                name: "PostgreSQL",
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
                filters: filterSettings(),
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

    private func languageSettingsView(language: AppLanguage) -> some View {
        let settings = AppLanguageSettings(selection: language)
        return IssueLightSettingsView(
            model: screenshotModel,
            languageSettings: settings,
            initialSelection: .language
        )
            .appLanguageEnvironment(settings)
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
