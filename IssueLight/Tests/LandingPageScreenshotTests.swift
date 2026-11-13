import AppKit
import IssueLightCore
import SwiftUI
import XCTest

@MainActor
final class LandingPageScreenshotTests: XCTestCase {
    func testLandingPageScreenshotsRenderFromProductionViews() throws {
        let statusData = try NativeViewRenderer.pngData(
            for: statusView,
            size: CGSize(width: 760, height: 560)
        )
        let sourceData = try NativeViewRenderer.pngData(
            for: sourceSetupView,
            size: CGSize(width: 920, height: 680)
        )

        XCTAssertGreaterThan(statusData.count, 50_000)
        XCTAssertGreaterThan(sourceData.count, 50_000)

        guard let outputPath = ProcessInfo.processInfo.environment["ISSUELIGHT_SCREENSHOT_OUTPUT_DIR"] else {
            return
        }
        let outputDirectory = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        try statusData.write(
            to: outputDirectory.appendingPathComponent("attention-overview.png"),
            options: .atomic
        )
        try sourceData.write(
            to: outputDirectory.appendingPathComponent("source-setup.png"),
            options: .atomic
        )
    }

    private var statusView: some View {
        let productionID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let homelabID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
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
                id: "edge-host",
                host: "edge-02",
                service: nil,
                name: "Edge gateway 02",
                severity: .critical,
                summary: "Host is unreachable"
            ),
            issue(
                sourceID: homelabID,
                id: "nas-storage",
                host: "nas",
                service: "Storage",
                name: "Storage",
                severity: .warning,
                summary: "WARNING: volume is 82% full"
            ),
            issue(
                sourceID: productionID,
                id: "worker-check",
                host: "worker-04",
                service: "Deployment check",
                name: "Deployment check",
                severity: .unknown,
                summary: "UNKNOWN: last result is older than 15 minutes"
            ),
        ]
        return StatusWindowContent(
            hasConfiguredSource: true,
            hasEnabledSource: true,
            hasActiveSnapshot: true,
            latestSuccessfulRefresh: Date(timeIntervalSince1970: 1_794_574_720),
            refreshState: .current,
            hasPartialRefreshFailure: false,
            failedSources: [],
            actionableIssues: issues,
            coveredIssues: [
                issue(
                    sourceID: productionID,
                    id: "maintenance",
                    host: "db-02",
                    service: "Backup",
                    name: "Backup",
                    severity: .warning,
                    summary: "WARNING: maintenance backup is running",
                    acknowledged: true
                ),
            ],
            sourceNames: [productionID: "Produktion", homelabID: "Homelab"],
            refresh: {},
            openSources: {}
        )
        .environment(\.locale, Locale(identifier: "de_DE"))
        .environment(\.colorScheme, .light)
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

    private func issue(
        sourceID: UUID,
        id: String,
        host: String,
        service: String?,
        name: String,
        severity: MonitoringSeverity,
        summary: String,
        acknowledged: Bool = false
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
            isAcknowledged: acknowledged,
            isInDowntime: false
        )
    }

}
