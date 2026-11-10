import XCTest
@testable import IssueLightCore

final class Icinga2ProviderTests: XCTestCase {
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

    private func source(endpoint: String) -> MonitoringSource {
        MonitoringSource(
            name: "Icinga",
            providerID: Icinga2Provider.id,
            endpoint: URL(string: endpoint)!,
            authentication: .basic(username: "operator")
        )
    }
}
