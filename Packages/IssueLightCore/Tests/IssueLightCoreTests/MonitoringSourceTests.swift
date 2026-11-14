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

    func testOlderStoredSourceDecodesWithoutNavigationConfiguration() throws {
        let encoded = try JSONEncoder().encode(source())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "web")
        object.removeValue(forKey: "remoteAccess")

        let decoded = try JSONDecoder().decode(
            MonitoringSource.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertNil(decoded.web)
        XCTAssertNil(decoded.remoteAccess)
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

        value = source(serverTrust: .pinnedCertificate(sha256: "not a fingerprint"))
        XCTAssertTrue(
            MonitoringSourceValidator.validateSharedFields(value).contains(.invalidPinnedCertificate)
        )
    }

    func testSharedValidationRejectsInvalidAuthenticationFields() {
        XCTAssertEqual(
            MonitoringSourceValidator.validateSharedFields(
                source(authentication: .basic(username: ""))
            ),
            [.emptyUsername]
        )
        XCTAssertEqual(
            MonitoringSourceValidator.validateSharedFields(
                source(authentication: .basic(username: "operator:password"))
            ),
            [.invalidUsername]
        )
        XCTAssertEqual(
            MonitoringSourceValidator.validateSharedFields(
                source(authentication: .clientCertificate(identityID: ""))
            ),
            [.missingClientIdentity]
        )
    }

    func testSharedValidationAcceptsWebAndRemoteActions() {
        let value = source(
            web: MonitoringWebConfiguration(
                baseURL: URL(string: "http://icinga-web.internal/icingaweb2")!,
                automaticSSHTunnel: SSHTunnelConfiguration(
                    bastionHost: "bastion.example.test",
                    username: "operator",
                    preferredLocalPort: 8_080
                )
            ),
            remoteAccess: RemoteAccessConfiguration(
                ssh: RemoteLoginConfiguration(username: "deploy", port: 22),
                rdp: RemoteLoginConfiguration(username: "admin", port: 3_389)
            )
        )

        XCTAssertTrue(MonitoringSourceValidator.validateSharedFields(value).isEmpty)
    }

    func testSharedValidationRejectsUnsafeOrIncompleteNavigationConfiguration() {
        let value = source(
            web: MonitoringWebConfiguration(
                baseURL: URL(string: "https://user:password@icinga-web.internal/icingaweb2?q=1")!,
                automaticSSHTunnel: SSHTunnelConfiguration(
                    bastionHost: " ",
                    username: " ",
                    port: 0,
                    preferredLocalPort: 70_000
                )
            ),
            remoteAccess: RemoteAccessConfiguration(
                ssh: RemoteLoginConfiguration(port: 0),
                rdp: RemoteLoginConfiguration(port: 70_000)
            )
        )

        XCTAssertEqual(
            Set(MonitoringSourceValidator.validateSharedFields(value)),
            Set([
                .invalidWebURL,
                .emptyBastionHost,
                .emptyBastionUsername,
                .invalidRemotePort(0),
                .invalidRemotePort(70_000),
                .secureWebTunnelUnsupported,
            ])
        )
    }

    func testRemoteActionURLsEncodeHostUserAndPort() throws {
        let monitoredIssue = MonitoringIssue(
            sourceID: UUID(),
            nativeID: "service",
            kind: .service,
            hostName: "db-01",
            serviceName: "Disk",
            displayName: "Disk",
            severity: .critical,
            summary: "Disk full",
            isAcknowledged: false,
            isInDowntime: false
        )

        XCTAssertEqual(
            IssueNavigationURL.ssh(
                for: monitoredIssue,
                configuration: RemoteLoginConfiguration(username: "deploy", port: 2_222)
            )?.absoluteString,
            "ssh://deploy@db-01:2222"
        )
        XCTAssertEqual(
            IssueNavigationURL.rdp(
                for: monitoredIssue,
                configuration: RemoteLoginConfiguration(username: "operator", port: 3_389)
            )?.absoluteString,
            "rdp://full%20address=s:db-01:3389&username=s:operator"
        )
    }

    func testRDPActionURLDoesNotAllowMonitoringDataToInjectAttributes() throws {
        let monitoredIssue = MonitoringIssue(
            sourceID: UUID(),
            nativeID: "host",
            kind: .host,
            hostName: "server&username=s:other",
            serviceName: nil,
            displayName: "Server",
            severity: .critical,
            summary: "DOWN",
            isAcknowledged: false,
            isInDowntime: false
        )

        XCTAssertEqual(
            IssueNavigationURL.rdp(
                for: monitoredIssue,
                configuration: RemoteLoginConfiguration(
                    username: "operator&gatewayhostname=s:evil",
                    port: 3_389
                )
            )?.absoluteString,
            "rdp://full%20address=s:server%26username%3Ds:other:3389&username=s:operator%26gatewayhostname%3Ds:evil"
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

    func testEndpointAuthorityNormalizesDefaultHTTPAndHTTPSPorts() {
        var httpsSource = source(endpoint: URL(string: "https://icinga.example.test/v1")!)
        var httpSource = source(endpoint: URL(string: "http://icinga.example.test/v1")!)

        XCTAssertFalse(
            httpsSource.updateEndpoint(URL(string: "https://icinga.example.test:443/v1/")!)
        )
        XCTAssertFalse(
            httpSource.updateEndpoint(URL(string: "http://icinga.example.test:80/v1/")!)
        )
    }

    func testEndpointWithoutAuthorityIsTreatedAsAuthorityChange() {
        var source = source(serverTrust: .pinnedCertificate(sha256: "ABC"))

        let authorityChanged = source.updateEndpoint(URL(string: "relative-endpoint")!)

        XCTAssertTrue(authorityChanged)
        XCTAssertEqual(source.serverTrust, .system)
    }

    func testDefaultTrustVerifiesServerCertificate() {
        XCTAssertTrue(source().serverTrust.verifiesServerCertificate)
        XCTAssertFalse(source(serverTrust: .disabled).serverTrust.verifiesServerCertificate)
        XCTAssertEqual(source().serverTrust.method, .system)
        XCTAssertEqual(
            source(serverTrust: .customCertificate(certificateID: "private-ca")).serverTrust.method,
            .customCertificate
        )
        XCTAssertEqual(
            source(serverTrust: .pinnedCertificate(sha256: "ABC")).serverTrust.method,
            .pinnedCertificate
        )
        XCTAssertEqual(source(serverTrust: .disabled).serverTrust.method, .disabled)
        XCTAssertNil(source().customServerCertificateID)
        XCTAssertEqual(
            source(serverTrust: .customCertificate(certificateID: "private-ca")).customServerCertificateID,
            "private-ca"
        )
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
        serverTrust: ServerTrustConfiguration = .system,
        web: MonitoringWebConfiguration? = nil,
        remoteAccess: RemoteAccessConfiguration? = nil
    ) -> MonitoringSource {
        MonitoringSource(
            name: name,
            providerID: Icinga2Provider.id,
            endpoint: endpoint,
            authentication: authentication,
            serverTrust: serverTrust,
            web: web,
            remoteAccess: remoteAccess
        )
    }
}
