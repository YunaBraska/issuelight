import Foundation
import Security
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

    func testClientCertificateChallengeDoesNotHideLaterRequestTimeout() {
        XCTAssertEqual(
            ProviderHTTPSession.failure(
                for: URLError(.timedOut),
                challengeFailure: .clientCertificateRejected
            ),
            .unreachable
        )
        XCTAssertEqual(
            ProviderHTTPSession.failure(
                for: URLError(.networkConnectionLost),
                challengeFailure: .clientCertificateRejected
            ),
            .clientCertificateRejected
        )
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

    func testSOCKSRoutingPreservesAPIKeyAndTrustedServerCertificate() throws {
        let certificateURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: "issuelight-test-root",
                withExtension: "crt",
                subdirectory: "Fixtures"
            )
        )
        let certificate = try ServerCertificateFingerprint.certificate(at: certificateURL)

        let access = ProviderAccess(
            credential: .apiKey("secret-key"),
            trustedServerCertificate: certificate
        ).routingThroughSOCKS(port: 4_218)

        guard case .apiKey(let apiKey) = access.credential else {
            return XCTFail("Expected API-key access to remain unchanged")
        }
        XCTAssertEqual(apiKey, "secret-key")
        XCTAssertEqual(access.socksProxy, ProviderSOCKSProxy(port: 4_218))
        let routedCertificate = try XCTUnwrap(access.trustedServerCertificate)
        XCTAssertTrue(CFEqual(routedCertificate, certificate))
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
