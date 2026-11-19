import IssueLightCore
import SwiftUI
import XCTest

@MainActor
final class SourceSecurityInteractionTests: XCTestCase {
    func testBlockedTLSConnectionRendersTrustActionBesideTrustPolicy() async throws {
        let provider = BlockedTLSProvider()
        let model = IssueLightModel(
            sourceStore: nil,
            providerRegistry: try ProviderRegistry([provider]),
            passwordVault: KeychainPasswordVault(),
            identityCatalog: KeychainIdentityCatalog(),
            certificateCatalog: KeychainServerCertificateCatalog(
                ownershipScope: "berlin.yuna.issuelight.blocked-tls-tests"
            ),
            startsAutomatically: false,
            localizationLocale: Locale(identifier: "de_DE")
        )
        model.beginAddingSource()
        model.endpoint = "monitoring.example.test"
        model.username = "monitoring"
        model.credentialSecret = "test-only-password"
        model.serverTrustChoice = .disabled

        await model.testConnection()

        XCTAssertTrue(model.canReviewBlockedServerCertificate)
        let view = SourceSetupView(model: model)
            .frame(width: 900, height: 720)
            .environment(\.locale, Locale(identifier: "de_DE"))
            .environment(\.colorScheme, .light)
        XCTAssertTrue(
            NativeViewRenderer.exerciseWindow(
                for: view,
                size: CGSize(width: 900, height: 720)
            )
        )
        if let outputPath = ProcessInfo.processInfo.environment[
            "ISSUELIGHT_BLOCKED_TLS_SCREENSHOT_PATH"
        ] {
            let pngData = try NativeViewRenderer.pngData(
                for: view,
                size: CGSize(width: 900, height: 720)
            )
            XCTAssertGreaterThan(pngData.count, 40_000)
            try pngData.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        }
    }

    func testPresentedCertificateReviewRendersFingerprintWithoutClipping() throws {
        let certificate = PresentedServerCertificate(
            endpoint: URL(string: "https://monitoring.example.test:5665")!,
            subject: "monitoring.example.test",
            issuer: "IssueLight Test CA",
            validFrom: Date(timeIntervalSince1970: 1_798_761_600),
            validUntil: Date(timeIntervalSince1970: 1_830_297_600),
            sha256Fingerprint: String(repeating: "A1:", count: 31) + "A1"
        )
        let view = PresentedServerCertificateTrustView(
            certificate: certificate,
            cancel: {},
            trust: {}
        )
        .environment(\.locale, Locale(identifier: "de_DE"))
        .environment(\.colorScheme, .light)
        let size = NativeViewRenderer.fittingSize(
            for: view,
            maximumSize: CGSize(width: 600, height: 500)
        )

        XCTAssertEqual(size.width, 520, accuracy: 1)
        XCTAssertGreaterThan(size.height, 290)
        XCTAssertLessThan(size.height, 500)
        XCTAssertTrue(NativeViewRenderer.exerciseWindow(for: view, size: size))
        if let outputPath = ProcessInfo.processInfo.environment[
            "ISSUELIGHT_CERTIFICATE_REVIEW_SCREENSHOT_PATH"
        ] {
            let pngData = try NativeViewRenderer.pngData(for: view, size: size)
            XCTAssertGreaterThan(pngData.count, 20_000)
            try pngData.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        }
    }
}

private struct BlockedTLSProvider: MonitoringProvider {
    static let id = ProviderID(rawValue: "blocked-tls-test")

    let descriptor = ProviderDescriptor(
        id: Self.id,
        displayName: "TLS Test",
        capabilities: ProviderCapabilities(
            authenticationMethods: [.basic],
            serverTrustMethods: [.system, .customCertificate, .pinnedCertificate, .disabled]
        )
    )

    func endpointCandidates(from hint: String) -> [URL] {
        let host = hint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return [] }
        return [URL(string: "https://\(host)")!]
    }

    func validate(_ source: MonitoringSource) -> [SourceValidationIssue] {
        MonitoringSourceValidator.validateSharedFields(source)
    }

    func testConnection(
        to source: MonitoringSource,
        access: ProviderAccess
    ) async -> ConnectionTestResult {
        .failed(.serverTrust)
    }

    func loadSnapshot(
        from source: MonitoringSource,
        access: ProviderAccess
    ) async -> SnapshotLoadResult {
        .failed(.serverTrust)
    }
}
