import XCTest
@testable import IssueLightCore

final class Icinga2ConnectionTesterTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.handler = nil
        StubURLProtocol.onStart = nil
        StubURLProtocol.blocksRequests = false
        StubURLProtocol.didStopLoading = false
        super.tearDown()
    }

    func testConnectionChecksHostsAndServicesThroughPublicIcingaEndpoints() async {
        var requests: [URLRequest] = []
        StubURLProtocol.handler = { request in
            requests.append(request)
            return Self.response(request: request, statusCode: 200, body: #"{"results":[]}"#)
        }

        let result = await tester().test(source(), password: "secret")

        XCTAssertEqual(result, .connected)
        XCTAssertEqual(requests.map { $0.url?.path }, ["/v1/objects/hosts", "/v1/objects/services"])
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Basic b3BlcmF0b3I6c2VjcmV0" })
    }

    func testConnectionMapsAuthenticationAndAuthorizationFailures() async {
        StubURLProtocol.handler = { request in
            Self.response(request: request, statusCode: 401, body: #"{"error":401}"#)
        }
        let authentication = await tester().test(source(), password: "wrong")
        XCTAssertEqual(authentication, .failed(.authentication))

        StubURLProtocol.handler = { request in
            Self.response(request: request, statusCode: 403, body: #"{"error":403}"#)
        }
        let authorization = await tester().test(source(), password: "secret")
        XCTAssertEqual(authorization, .failed(.authorization))
    }

    func testConnectionRejectsNonIcingaResponse() async {
        StubURLProtocol.handler = { request in
            Self.response(request: request, statusCode: 200, body: #"{"status":"ok"}"#)
        }

        let result = await tester().test(source(), password: "secret")

        XCTAssertEqual(result, .failed(.incompatibleResponse))
    }

    func testConnectionDoesNotPretendUnsupportedTrustAndClientIdentityWork() async {
        var customTrust = source()
        customTrust.serverTrust = .customCertificate(certificateID: "ca")
        let trustResult = await tester().test(customTrust, password: "secret")
        XCTAssertEqual(trustResult, .failed(.unsupportedTrustConfiguration))

        var clientCertificate = source()
        clientCertificate.authentication = .clientCertificate(identityID: "identity")
        let identityResult = await tester().test(clientCertificate, clientIdentity: nil)
        XCTAssertEqual(identityResult, .failed(.clientCertificateNotAvailable))
    }

    func testConnectionCancellationStopsTheActiveRequest() async {
        let started = expectation(description: "Request started")
        StubURLProtocol.blocksRequests = true
        StubURLProtocol.onStart = { started.fulfill() }
        let connection = Task {
            await self.tester().test(self.source(), password: "secret")
        }
        await fulfillment(of: [started], timeout: 1)

        connection.cancel()
        let result = await connection.value

        XCTAssertEqual(result, .failed(.cancelled))
        XCTAssertTrue(StubURLProtocol.didStopLoading)
    }

    private func tester() -> Icinga2ConnectionTester {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return Icinga2ConnectionTester(configuration: configuration)
    }

    private func source() -> MonitoringSource {
        MonitoringSource(
            name: "Production",
            providerID: Icinga2Provider.id,
            endpoint: URL(string: "https://icinga.example.test:5665/v1")!,
            authentication: .basic(username: "operator")
        )
    }

    private static func response(request: URLRequest, statusCode: Int, body: String) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(body.utf8))
    }
}

final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    static var onStart: (() -> Void)?
    static var blocksRequests = false
    static var didStopLoading = false

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.onStart?()
        if Self.blocksRequests { return }
        guard let handler = Self.handler else {
            XCTFail("Missing URL protocol handler")
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        Self.didStopLoading = true
    }
}
