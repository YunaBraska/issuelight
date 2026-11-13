import XCTest
@testable import IssueLightCore

final class Icinga2ConnectionTesterTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.handler = nil
        StubURLProtocol.onStart = nil
        StubURLProtocol.blocksRequests = false
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
        XCTAssertEqual(
            requests.map { request in
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            },
            [
                [URLQueryItem(name: "attrs", value: "name"), URLQueryItem(name: "limit", value: "1")],
                [URLQueryItem(name: "attrs", value: "name"), URLQueryItem(name: "limit", value: "1")],
            ]
        )
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
        XCTAssertTrue(requests.allSatisfy { $0.timeoutInterval == 15 })
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Accept") == "application/json" })
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "User-Agent") == "IssueLight" })
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Basic b3BlcmF0b3I6c2VjcmV0" })
    }

    func testConnectionRejectsMissingAndEmptyPasswordsBeforeSendingARequest() async {
        let missing = await tester().test(source(), password: nil)
        let empty = await tester().test(source(), password: "")

        XCTAssertEqual(missing, .failed(.authentication))
        XCTAssertEqual(empty, .failed(.authentication))
    }

    func testConnectionRejectsInvalidSourceBeforeSendingARequest() async {
        var invalidSource = source()
        invalidSource.endpoint = URL(string: "http://icinga.example.test:5665/custom")!

        let result = await tester().test(invalidSource, password: "secret")

        XCTAssertEqual(
            result,
            .failed(.invalidConfiguration([.unsupportedScheme("http"), .unsupportedPath("/custom")]))
        )
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

    func testConnectionRejectsMalformedJSONResponse() async {
        StubURLProtocol.handler = { request in
            Self.response(request: request, statusCode: 200, body: "not-json")
        }

        let result = await tester().test(source(), password: "secret")

        XCTAssertEqual(result, .failed(.incompatibleResponse))
    }

    func testConnectionRejectsNonObjectJSONResponse() async {
        StubURLProtocol.handler = { request in
            Self.response(request: request, statusCode: 200, body: #"[]"#)
        }

        let result = await tester().test(source(), password: "secret")

        XCTAssertEqual(result, .failed(.incompatibleResponse))
    }

    func testConnectionRejectsNonHTTPResponse() async {
        StubURLProtocol.handler = { request in
            (
                URLResponse(
                    url: request.url!,
                    mimeType: "application/json",
                    expectedContentLength: 14,
                    textEncodingName: "utf-8"
                ),
                Data(#"{"results":[]}"#.utf8)
            )
        }

        let result = await tester().test(source(), password: "secret")

        XCTAssertEqual(result, .failed(.incompatibleResponse))
    }

    func testConnectionMapsServerFailure() async {
        StubURLProtocol.handler = { request in
            Self.response(request: request, statusCode: 503, body: #"{"error":503}"#)
        }

        let result = await tester().test(source(), password: "secret")

        XCTAssertEqual(result, .failed(.server(statusCode: 503)))
    }

    func testConnectionMapsUnexpectedHTTPFailure() async {
        StubURLProtocol.handler = { request in
            Self.response(request: request, statusCode: 429, body: #"{"error":429}"#)
        }

        let result = await tester().test(source(), password: "secret")

        XCTAssertEqual(result, .failed(.http(statusCode: 429)))
    }

    func testConnectionMapsTLSFailure() async {
        StubURLProtocol.handler = { _ in
            throw URLError(.serverCertificateHasUnknownRoot)
        }

        let result = await tester().test(source(), password: "secret")

        XCTAssertEqual(result, .failed(.tls))
    }

    func testConnectionMapsReachabilityFailure() async {
        StubURLProtocol.handler = { _ in
            throw URLError(.timedOut)
        }

        let result = await tester().test(source(), password: "secret")

        XCTAssertEqual(result, .failed(.unreachable))
    }

    func testConnectionMapsUnknownTransportFailureToUnreachable() async {
        StubURLProtocol.handler = { _ in
            throw NSError(domain: "IssueLightTests", code: 99)
        }

        let result = await tester().test(source(), password: "secret")

        XCTAssertEqual(result, .failed(.unreachable))
    }

    func testConnectionRequiresConfiguredTrustMaterialAndClientIdentity() async {
        var customTrust = source()
        customTrust.serverTrust = .customCertificate(certificateID: "ca")
        let trustResult = await tester().test(customTrust, password: "secret")
        XCTAssertEqual(trustResult, .failed(.serverCertificateNotAvailable))

        var pinnedTrust = source()
        pinnedTrust.serverTrust = .pinnedCertificate(sha256: "ABC")
        let pinnedResult = await tester().test(pinnedTrust, password: "secret")
        XCTAssertEqual(pinnedResult, .failed(.invalidConfiguration([.invalidPinnedCertificate])))

        var clientCertificate = source()
        clientCertificate.authentication = .clientCertificate(identityID: "identity")
        let identityResult = await tester().test(clientCertificate, clientIdentity: nil)
        XCTAssertEqual(identityResult, .failed(.clientCertificateNotAvailable))
    }

    func testConnectionCancellationReturnsCancelled() async {
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
    static var handler: ((URLRequest) throws -> (URLResponse, Data))?
    static var onStart: (() -> Void)?
    static var blocksRequests = false

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

    override func stopLoading() {}
}
