import Security
import XCTest
@testable import IssueLightCore

final class ProviderAccessResolverTests: XCTestCase {
    func testResolverCombinesStoredPasswordAndCustomServerCertificate() async throws {
        let fileURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: "issuelight-test-root",
                withExtension: "crt",
                subdirectory: "Fixtures"
            )
        )
        let certificateCatalog = KeychainServerCertificateCatalog()
        let certificateDescriptor = try await certificateCatalog.importCertificate(at: fileURL)
        let source = MonitoringSource(
            name: "Private CA",
            providerID: Icinga2Provider.id,
            endpoint: URL(string: "https://private-ca.example.test:5665")!,
            authentication: .basic(username: "operator"),
            serverTrust: .customCertificate(certificateID: certificateDescriptor.id)
        )
        let passwordVault = KeychainPasswordVault()
        let passwordScope = try BasicCredentialScope(source: source)
        addTeardownBlock {
            try? await passwordVault.deletePassword(for: passwordScope)
            try? await certificateCatalog.deleteCertificate(id: certificateDescriptor.id)
        }
        try await passwordVault.store("test-only-password", for: passwordScope)
        let resolver = ProviderAccessResolver(
            passwordVault: passwordVault,
            identityCatalog: KeychainIdentityCatalog(),
            certificateCatalog: certificateCatalog
        )

        let resolution = await resolver.resolve(source: source)

        guard case .resolved(let access) = resolution else {
            return XCTFail("Expected resolved provider access")
        }
        guard case .password(let password) = access.credential else {
            return XCTFail("Expected a password credential")
        }
        XCTAssertEqual(password, "test-only-password")
        XCTAssertNotNil(access.trustedServerCertificate)
    }

    func testResolverReportsMissingStoredPasswordWithoutFallback() async throws {
        let source = MonitoringSource(
            name: "Missing password",
            providerID: Icinga2Provider.id,
            endpoint: URL(string: "https://missing-password.example.test:5665")!,
            authentication: .basic(username: "operator")
        )
        let resolver = ProviderAccessResolver(
            passwordVault: KeychainPasswordVault(),
            identityCatalog: KeychainIdentityCatalog(),
            certificateCatalog: KeychainServerCertificateCatalog()
        )

        let resolution = await resolver.resolve(source: source)

        guard case .failed(let failure) = resolution else {
            return XCTFail("Expected provider access failure")
        }
        XCTAssertEqual(failure, .passwordNotAvailable)
    }

    func testResolverRejectsMissingCustomCertificateBeforeUsingCredential() async {
        let source = MonitoringSource(
            name: "Missing CA",
            providerID: Icinga2Provider.id,
            endpoint: URL(string: "https://missing-ca.example.test:5665")!,
            authentication: .basic(username: "operator"),
            serverTrust: .customCertificate(
                certificateID: Data("missing-certificate".utf8).base64EncodedString()
            )
        )
        let resolver = ProviderAccessResolver(
            passwordVault: KeychainPasswordVault(),
            identityCatalog: KeychainIdentityCatalog(),
            certificateCatalog: KeychainServerCertificateCatalog()
        )

        let resolution = await resolver.resolve(
            source: source,
            passwordOverride: "must-not-hide-missing-ca"
        )

        guard case .failed(let failure) = resolution else {
            return XCTFail("Expected provider access failure")
        }
        XCTAssertEqual(failure, .serverCertificateNotAvailable)
    }
}
