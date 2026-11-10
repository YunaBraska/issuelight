import XCTest
@testable import IssueLightCore

final class MonitoringSourceTests: XCTestCase {
    func testSourceEncodingContainsNoPasswordOrPrivateKey() throws {
        let source = source(authentication: .basic(username: "operator"))

        let json = String(decoding: try JSONEncoder().encode(source), as: UTF8.self)

        XCTAssertTrue(json.contains("operator"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("password"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("privateKey"))
    }

    func testSharedValidationRejectsInvalidPublicConfiguration() {
        var value = source(name: " ", endpoint: URL(string: "ftp://user:pass@example.test/path?q=1#fragment")!)

        let issues = MonitoringSourceValidator.validateSharedFields(value)

        XCTAssertEqual(
            Set(issues),
            Set([.emptyName, .unsupportedScheme("ftp"), .embeddedCredentials, .queryNotAllowed, .fragmentNotAllowed])
        )

        value = source(endpoint: URL(string: "https:///v1")!)
        XCTAssertTrue(MonitoringSourceValidator.validateSharedFields(value).contains(.missingHost))

        value = source(serverTrust: .customCertificate(certificateID: ""))
        XCTAssertTrue(
            MonitoringSourceValidator.validateSharedFields(value).contains(.missingServerCertificate)
        )
    }

    func testEndpointAuthorityChangeRestoresSystemTrust() {
        var source = source(serverTrust: .disabled)

        let authorityChanged = source.updateEndpoint(URL(string: "https://other.example.test:5665/v1")!)

        XCTAssertTrue(authorityChanged)
        XCTAssertEqual(source.serverTrust, .system)
    }

    func testEndpointPathChangePreservesTrustForSameAuthority() {
        var source = source(serverTrust: .pinnedCertificate(sha256: "ABC"))

        let authorityChanged = source.updateEndpoint(URL(string: "https://icinga.example.test:5665/v1/")!)

        XCTAssertFalse(authorityChanged)
        XCTAssertEqual(source.serverTrust, .pinnedCertificate(sha256: "ABC"))
    }

    func testDefaultTrustVerifiesServerCertificate() {
        XCTAssertTrue(source().serverTrust.verifiesServerCertificate)
        XCTAssertFalse(source(serverTrust: .disabled).serverTrust.verifiesServerCertificate)
        XCTAssertEqual(source().serverTrust.method, .system)
        XCTAssertEqual(source(serverTrust: .disabled).serverTrust.method, .disabled)
    }

    func testChangingVerificationPreservesSpecificTrustUntilItIsExplicitlyDisabled() {
        var source = source(serverTrust: .customCertificate(certificateID: "private-ca"))

        source.setServerCertificateVerification(enabled: true)
        XCTAssertEqual(source.serverTrust, .customCertificate(certificateID: "private-ca"))

        source.setServerCertificateVerification(enabled: false)
        XCTAssertEqual(source.serverTrust, .disabled)

        source.setServerCertificateVerification(enabled: true)
        XCTAssertEqual(source.serverTrust, .system)
    }

    private func source(
        name: String = "Production",
        endpoint: URL = URL(string: "https://icinga.example.test:5665/v1")!,
        authentication: AuthenticationConfiguration = .basic(username: "operator"),
        serverTrust: ServerTrustConfiguration = .system
    ) -> MonitoringSource {
        MonitoringSource(
            name: name,
            providerID: Icinga2Provider.id,
            endpoint: endpoint,
            authentication: authentication,
            serverTrust: serverTrust
        )
    }
}
