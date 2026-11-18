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
}
