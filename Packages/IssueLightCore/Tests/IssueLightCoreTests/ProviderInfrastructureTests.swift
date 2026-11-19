import Foundation
import XCTest
@testable import IssueLightCore

final class ProviderInfrastructureTests: XCTestCase {
    func testEveryServerCertificateErrorIsClassifiedAsServerTrust() {
        for code in [
            URLError.Code.serverCertificateHasBadDate,
            .serverCertificateUntrusted,
            .serverCertificateHasUnknownRoot,
            .serverCertificateNotYetValid,
        ] {
            XCTAssertEqual(ProviderHTTPSession.failure(for: URLError(code)), .serverTrust)
        }
    }

    func testSecureConnectionFailureIsClassifiedAsTLSHandshake() {
        XCTAssertEqual(ProviderHTTPSession.failure(for: URLError(.secureConnectionFailed)), .tls)
    }

    func testEveryClientCertificateErrorIsClassifiedSeparately() {
        for code in [
            URLError.Code.clientCertificateRejected,
            .clientCertificateRequired,
        ] {
            XCTAssertEqual(
                ProviderHTTPSession.failure(for: URLError(code)),
                .clientCertificateRejected
            )
        }
    }

    func testSOCKSRoutingPreservesAccessAndConfiguresAnIndependentSessionCopy() {
        let access = ProviderAccess(credential: .password("secret"))
            .routingThroughSOCKS(port: 4_217)

        XCTAssertEqual(access.socksProxy, ProviderSOCKSProxy(port: 4_217))
        guard case .password(let password) = access.credential else {
            return XCTFail("Expected password access to remain unchanged")
        }
        XCTAssertEqual(password, "secret")

        let original = URLSessionConfiguration.ephemeral
        let routed = original.routed(through: access.socksProxy)

        XCTAssertTrue(original.proxyConfigurations.isEmpty)
        XCTAssertEqual(routed.proxyConfigurations.count, 1)
    }

    func testSessionRoutingIgnoresMissingAndInvalidSOCKSPorts() {
        let original = URLSessionConfiguration.ephemeral

        XCTAssertTrue(original.routed(through: nil).proxyConfigurations.isEmpty)
        XCTAssertTrue(
            original.routed(through: ProviderSOCKSProxy(port: 0)).proxyConfigurations.isEmpty
        )
        XCTAssertTrue(
            original.routed(through: ProviderSOCKSProxy(port: 65_536)).proxyConfigurations.isEmpty
        )
    }
}
