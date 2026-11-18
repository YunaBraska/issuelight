import XCTest
@testable import IssueLightCore

final class PresentedServerCertificateTests: XCTestCase {
    func testFetcherRejectsNonHTTPSEndpointWithoutNetworkAccess() async {
        let result = await PresentedServerCertificateFetcher.fetch(
            from: URL(string: "http://monitoring.example.test:5665")!
        )

        XCTAssertEqual(
            result,
            .failed(.invalidConfiguration([.unsupportedScheme("http")]))
        )
    }

    func testCertificateReviewContainsIdentityAndValidityDetails() throws {
        let fileURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: "issuelight-test-root",
                withExtension: "crt",
                subdirectory: "Fixtures"
            )
        )
        let certificate = try ServerCertificateFingerprint.certificate(at: fileURL)

        let presented = PresentedServerCertificate(
            endpoint: URL(string: "https://monitoring.example.test")!,
            certificate: certificate
        )

        XCTAssertFalse(presented.subject.isEmpty)
        XCTAssertFalse(presented.issuer?.isEmpty ?? true)
        XCTAssertNotNil(presented.validFrom)
        XCTAssertNotNil(presented.validUntil)
        if let validFrom = presented.validFrom, let validUntil = presented.validUntil {
            XCTAssertLessThan(validFrom, validUntil)
        }
        XCTAssertEqual(presented.sha256Fingerprint.split(separator: ":").count, 32)
    }
}
