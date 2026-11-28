import Security
import XCTest
@testable import IssueLightCore

final class ProviderAccessResolverTests: XCTestCase {
    private var testKeychain: TemporaryTestKeychain!

    override func setUpWithError() throws {
        testKeychain = try TemporaryTestKeychain()
    }

    override func tearDownWithError() throws {
        try testKeychain.delete()
        testKeychain = nil
    }

    func testResolverUsesPasswordOverrideWhenStoredPasswordAccessIsDisabled() async {
        let source = MonitoringSource(
            name: "Edited credentials",
            providerID: Icinga2Provider.id,
            endpoint: URL(string: "https://edited-credentials.example.test:5665")!,
            authentication: .basic(username: "operator")
        )
        let resolver = ProviderAccessResolver(
            passwordVault: passwordVault(),
            identityCatalog: identityCatalog(),
            certificateCatalog: certificateCatalog()
        )

        let resolution = await resolver.resolve(
            source: source,
            credentialOverride: "replacement-password",
            allowsStoredCredential: false
        )

        guard case .resolved(let access) = resolution,
              case .password(let password) = access.credential else {
            return XCTFail("Expected password override to resolve provider access")
        }
        XCTAssertEqual(password, "replacement-password")
        XCTAssertNil(access.trustedServerCertificate)
    }

    func testResolverUsesStoredAPIKeyWithoutTreatingItAsBasicPassword() async throws {
        let source = MonitoringSource(
            name: "Thruk API key",
            providerID: ThrukProvider.id,
            endpoint: URL(string: "https://thruk-api-key.example.test/thruk/r/v1")!,
            authentication: .apiKey(username: "automation")
        )
        let vault = passwordVault()
        let scope = try APIKeyCredentialScope(source: source)
        addTeardownBlock {
            try? await vault.deleteAPIKey(for: scope)
        }
        try await vault.store("stored-api-key", for: scope)
        let resolver = ProviderAccessResolver(
            passwordVault: vault,
            identityCatalog: identityCatalog(),
            certificateCatalog: certificateCatalog()
        )

        let resolution = await resolver.resolve(source: source)

        guard case .resolved(let access) = resolution,
              case .apiKey(let value) = access.credential else {
            return XCTFail("Expected API key provider access")
        }
        XCTAssertEqual(value, "stored-api-key")
    }

    func testResolverReportsMissingStoredAPIKey() async {
        let source = MonitoringSource(
            name: "Missing Thruk API key",
            providerID: ThrukProvider.id,
            endpoint: URL(string: "https://missing-api-key.example.test/thruk/r/v1")!,
            authentication: .apiKey(username: "")
        )
        let resolver = ProviderAccessResolver(
            passwordVault: passwordVault(),
            identityCatalog: identityCatalog(),
            certificateCatalog: certificateCatalog()
        )

        let resolution = await resolver.resolve(source: source)

        guard case .failed(let failure) = resolution else {
            return XCTFail("Expected missing API key failure")
        }
        XCTAssertEqual(failure, .apiKeyNotAvailable)
    }

    func testResolverDoesNotReadStoredPasswordWhenAccessIsDisabled() async throws {
        let source = MonitoringSource(
            name: "Stored credential disabled",
            providerID: Icinga2Provider.id,
            endpoint: URL(string: "https://stored-credential-disabled.example.test:5665")!,
            authentication: .basic(username: "operator")
        )
        let passwordVault = passwordVault()
        let passwordScope = try BasicCredentialScope(source: source)
        addTeardownBlock {
            try? await passwordVault.deletePassword(for: passwordScope)
        }
        try await passwordVault.store("stored-password", for: passwordScope)
        let resolver = ProviderAccessResolver(
            passwordVault: passwordVault,
            identityCatalog: identityCatalog(),
            certificateCatalog: certificateCatalog()
        )

        let resolution = await resolver.resolve(
            source: source,
            allowsStoredCredential: false
        )

        guard case .failed(let failure) = resolution else {
            return XCTFail("Expected unavailable password failure")
        }
        XCTAssertEqual(failure, .passwordNotAvailable)
    }

    func testResolverReportsMissingClientIdentity() async {
        let missingReference = Data("missing-client-identity".utf8).base64EncodedString()
        let source = MonitoringSource(
            name: "Missing identity",
            providerID: Icinga2Provider.id,
            endpoint: URL(string: "https://missing-identity.example.test:5665")!,
            authentication: .clientCertificate(identityID: missingReference)
        )
        let resolver = ProviderAccessResolver(
            passwordVault: passwordVault(),
            identityCatalog: identityCatalog(),
            certificateCatalog: certificateCatalog()
        )

        let resolution = await resolver.resolve(source: source)

        guard case .failed(let failure) = resolution else {
            return XCTFail("Expected missing client identity failure")
        }
        XCTAssertEqual(failure, .clientIdentityNotAvailable)
    }

    func testResolverReportsInvalidClientIdentityReferenceAsAccessFailure() async {
        let source = MonitoringSource(
            name: "Invalid identity",
            providerID: Icinga2Provider.id,
            endpoint: URL(string: "https://invalid-identity.example.test:5665")!,
            authentication: .clientCertificate(identityID: "not base64")
        )
        let resolver = ProviderAccessResolver(
            passwordVault: passwordVault(),
            identityCatalog: identityCatalog(),
            certificateCatalog: certificateCatalog()
        )

        let resolution = await resolver.resolve(source: source)

        guard case .failed(let failure) = resolution else {
            return XCTFail("Expected client identity access failure")
        }
        XCTAssertEqual(failure, .clientIdentityAccessFailed)
    }

    func testResolverReportsInvalidServerCertificateReferenceAsAccessFailure() async {
        let source = MonitoringSource(
            name: "Invalid CA reference",
            providerID: Icinga2Provider.id,
            endpoint: URL(string: "https://invalid-ca-reference.example.test:5665")!,
            authentication: .basic(username: "operator"),
            serverTrust: .customCertificate(certificateID: "not base64")
        )
        let resolver = ProviderAccessResolver(
            passwordVault: passwordVault(),
            identityCatalog: identityCatalog(),
            certificateCatalog: certificateCatalog()
        )

        let resolution = await resolver.resolve(
            source: source,
            credentialOverride: "must-not-hide-invalid-ca"
        )

        guard case .failed(let failure) = resolution else {
            return XCTFail("Expected server certificate access failure")
        }
        XCTAssertEqual(failure, .serverCertificateAccessFailed)
    }

    func testResolverCombinesStoredPasswordAndCustomServerCertificate() async throws {
        let fileURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: "issuelight-test-root",
                withExtension: "crt",
                subdirectory: "Fixtures"
            )
        )
        let certificateCatalog = certificateCatalog()
        let certificateDescriptor = try await certificateCatalog.importCertificate(at: fileURL)
        let source = MonitoringSource(
            name: "Private CA",
            providerID: Icinga2Provider.id,
            endpoint: URL(string: "https://private-ca.example.test:5665")!,
            authentication: .basic(username: "operator"),
            serverTrust: .customCertificate(certificateID: certificateDescriptor.id)
        )
        let passwordVault = passwordVault()
        let passwordScope = try BasicCredentialScope(source: source)
        addTeardownBlock {
            try? await passwordVault.deletePassword(for: passwordScope)
            try? await certificateCatalog.deleteCertificate(id: certificateDescriptor.id)
        }
        try await passwordVault.store("test-only-password", for: passwordScope)
        let resolver = ProviderAccessResolver(
            passwordVault: passwordVault,
            identityCatalog: identityCatalog(),
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
            passwordVault: passwordVault(),
            identityCatalog: identityCatalog(),
            certificateCatalog: certificateCatalog()
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
            passwordVault: passwordVault(),
            identityCatalog: identityCatalog(),
            certificateCatalog: certificateCatalog()
        )

        let resolution = await resolver.resolve(
            source: source,
            credentialOverride: "must-not-hide-missing-ca"
        )

        guard case .failed(let failure) = resolution else {
            return XCTFail("Expected provider access failure")
        }
        XCTAssertEqual(failure, .serverCertificateNotAvailable)
    }

    func testResolverDoesNotReadTLSCertificateForPlainHTTP() async {
        let source = MonitoringSource(
            name: "HTTP source with stale trust setting",
            providerID: Icinga2Provider.id,
            endpoint: URL(string: "http://monitoring.example.test:8080")!,
            authentication: .basic(username: "operator"),
            serverTrust: .customCertificate(certificateID: "invalid-and-unused-over-http")
        )
        let resolver = ProviderAccessResolver(
            passwordVault: passwordVault(),
            identityCatalog: identityCatalog(),
            certificateCatalog: certificateCatalog()
        )

        let resolution = await resolver.resolve(
            source: source,
            credentialOverride: "http-password"
        )

        guard case .resolved(let access) = resolution,
              case .password(let password) = access.credential else {
            return XCTFail("Plain HTTP must not resolve an unused TLS certificate")
        }
        XCTAssertEqual(password, "http-password")
        XCTAssertNil(access.trustedServerCertificate)
    }

    private func passwordVault() -> KeychainPasswordVault {
        KeychainPasswordVault(keychainContext: testKeychain.context)
    }

    private func identityCatalog() -> KeychainIdentityCatalog {
        KeychainIdentityCatalog(accessContext: testKeychain.context)
    }

    private func certificateCatalog() -> KeychainServerCertificateCatalog {
        KeychainServerCertificateCatalog(
            ownershipScope: "berlin.yuna.issuelight.provider-tests.\(UUID().uuidString)",
            accessContext: testKeychain.context
        )
    }
}
