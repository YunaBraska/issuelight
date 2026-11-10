import Foundation
import XCTest
@testable import IssueLightCore

final class Icinga2ProviderTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    func testBuiltInRegistryPublishesIcingaCapabilities() throws {
        let registry = ProviderRegistry.builtIn()
        let provider = try XCTUnwrap(registry.provider(for: Icinga2Provider.id))

        XCTAssertEqual(registry.descriptors.map(\.displayName), ["Icinga 2"])
        XCTAssertEqual(provider.descriptor.capabilities.authenticationMethods, [.basic, .clientCertificate])
        XCTAssertEqual(provider.descriptor.capabilities.serverTrustMethods, [.system, .disabled])
        XCTAssertFalse(provider.descriptor.capabilities.supportsAcknowledgement)
        XCTAssertFalse(provider.descriptor.capabilities.supportsDowntime)
    }

    func testRegistryRejectsDuplicateProviderIDs() {
        XCTAssertThrowsError(try ProviderRegistry([Icinga2Provider(), Icinga2Provider()])) { error in
            XCTAssertEqual(error as? ProviderRegistryError, .duplicateProvider(Icinga2Provider.id))
        }
    }

    func testIcingaRequiresHTTPSAndSupportedRootPath() {
        let provider = Icinga2Provider()

        XCTAssertEqual(
            provider.validate(source(endpoint: "http://icinga.example.test:5665/v1")),
            [.unsupportedScheme("http")]
        )
        XCTAssertEqual(
            provider.validate(source(endpoint: "https://icinga.example.test:5665/custom")),
            [.unsupportedPath("/custom")]
        )
    }

    func testIcingaBuildsStatusURLFromRootAndVersionedEndpoint() throws {
        let provider = Icinga2Provider()

        XCTAssertEqual(
            try provider.statusURL(for: source(endpoint: "https://icinga.example.test:5665")),
            URL(string: "https://icinga.example.test:5665/v1/status")
        )
        XCTAssertEqual(
            try provider.statusURL(for: source(endpoint: "https://icinga.example.test:5665/v1/")),
            URL(string: "https://icinga.example.test:5665/v1/status")
        )
    }

    func testRegisteredProviderLoadsProviderNeutralSnapshot() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        StubURLProtocol.handler = { request in
            let body = request.url?.path.hasSuffix("/hosts") == true
                ? #"{"results":[{"attrs":{"acknowledgement":0,"display_name":"Edge","downtime_depth":0,"name":"edge-1","state":1},"name":"edge-1","type":"Host"}]}"#
                : #"{"results":[]}"#
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(body.utf8)
            )
        }
        let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let registry = try ProviderRegistry([
            Icinga2Provider(configuration: configuration, now: { observedAt }),
        ])
        let provider = try XCTUnwrap(registry.provider(for: Icinga2Provider.id))

        let result = await provider.loadSnapshot(
            from: source(endpoint: "https://icinga.example.test:5665"),
            credential: .password("secret")
        )

        guard case .loaded(let snapshot) = result else {
            return XCTFail("Expected provider snapshot, got \(result)")
        }
        XCTAssertEqual(snapshot.observedAt, observedAt)
        XCTAssertEqual(snapshot.issues.map(\.displayName), ["Edge"])
    }

    private func source(endpoint: String) -> MonitoringSource {
        MonitoringSource(
            name: "Icinga",
            providerID: Icinga2Provider.id,
            endpoint: URL(string: endpoint)!,
            authentication: .basic(username: "operator")
        )
    }
}
