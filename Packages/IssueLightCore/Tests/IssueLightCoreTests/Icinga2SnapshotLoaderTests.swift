import Foundation
import XCTest
@testable import IssueLightCore

final class Icinga2SnapshotLoaderTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.handler = nil
        StubURLProtocol.onStart = nil
        StubURLProtocol.blocksRequests = false
        super.tearDown()
    }

    func testLoadUsesProblemFiltersAndReturnsProviderNeutralSnapshot() async throws {
        let recorder = RequestRecorder()
        StubURLProtocol.handler = { request in
            recorder.append(request)
            let path = try XCTUnwrap(request.url?.path)
            if path.hasSuffix("/hosts") {
                return Self.response(
                    request: request,
                    statusCode: 200,
                    body: #"{"results":[{"attrs":{"acknowledgement":0,"display_name":"Router","downtime_depth":0,"last_check_result":{"output":"Host unreachable"},"name":"router-1","state":1},"name":"router-1","type":"Host"}]}"#
                )
            }
            return Self.response(
                request: request,
                statusCode: 200,
                body: #"{"results":[]}"#
            )
        }
        let observedAt = Date(timeIntervalSince1970: 1_800_000_000)

        let result = await loader(now: observedAt).load(source(), password: "secret")

        guard case .loaded(let snapshot) = result else {
            return XCTFail("Expected a loaded snapshot, got \(result)")
        }
        XCTAssertEqual(snapshot.observedAt, observedAt)
        XCTAssertEqual(snapshot.issues.map(\.displayName), ["Router"])
        let requests = recorder.requests
        XCTAssertEqual(Set(requests.compactMap { $0.url?.path }), ["/v1/objects/hosts", "/v1/objects/services"])
        XCTAssertTrue(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Basic b3BlcmF0b3I6c2VjcmV0"
        })
        let filters = requests.compactMap { request in
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "filter" })?
                .value
        }
        XCTAssertEqual(Set(filters), ["host.state!=0", "service.state!=0"])
    }

    func testLoadKeepsAuthenticationFailureDistinctFromHealthySnapshot() async {
        StubURLProtocol.handler = { request in
            Self.response(request: request, statusCode: 401, body: #"{"error":401}"#)
        }

        let result = await loader().load(source(), password: "wrong")

        XCTAssertEqual(result, .failed(.authentication))
    }

    func testLoadRejectsMissingPasswordBeforeRequest() async {
        let result = await loader().load(source(), password: nil)

        XCTAssertEqual(result, .failed(.authentication))
    }

    func testLoadRejectsMissingClientIdentityBeforeRequest() async {
        var clientCertificateSource = source()
        clientCertificateSource.authentication = .clientCertificate(identityID: "identity")

        let result = await loader().load(clientCertificateSource, clientIdentity: nil)

        XCTAssertEqual(result, .failed(.clientCertificateNotAvailable))
    }

    func testLoadMapsServerFailure() async {
        StubURLProtocol.handler = { request in
            Self.response(request: request, statusCode: 503, body: #"{"error":503}"#)
        }

        let result = await loader().load(source(), password: "secret")

        XCTAssertEqual(result, .failed(.server(statusCode: 503)))
    }

    func testLoadMapsUnexpectedHTTPFailure() async {
        StubURLProtocol.handler = { request in
            Self.response(request: request, statusCode: 429, body: #"{"error":429}"#)
        }

        let result = await loader().load(source(), password: "secret")

        XCTAssertEqual(result, .failed(.http(statusCode: 429)))
    }

    func testLoadMapsTLSFailure() async {
        StubURLProtocol.handler = { _ in
            throw URLError(.secureConnectionFailed)
        }

        let result = await loader().load(source(), password: "secret")

        XCTAssertEqual(result, .failed(.tls))
    }

    func testLoadMapsReachabilityFailure() async {
        StubURLProtocol.handler = { _ in
            throw URLError(.timedOut)
        }

        let result = await loader().load(source(), password: "secret")

        XCTAssertEqual(result, .failed(.unreachable))
    }

    func testLoadMapsUnexpectedTransportErrorToReachabilityFailure() async {
        StubURLProtocol.handler = { _ in
            throw NSError(domain: "IssueLightTests", code: 1)
        }

        let result = await loader().load(source(), password: "secret")

        XCTAssertEqual(result, .failed(.unreachable))
    }

    func testLoadRejectsNonHTTPResponse() async {
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

        let result = await loader().load(source(), password: "secret")

        XCTAssertEqual(result, .failed(.incompatibleResponse))
    }

    func testLoadRejectsHostResultWithWrongObjectType() async {
        let result = await load(
            hostBody: #"{"results":[{"attrs":{"acknowledgement":0,"display_name":"Host","downtime_depth":0,"name":"host-1","state":1},"name":"host-1","type":"Service"}]}"#
        )

        XCTAssertEqual(result, .failed(.incompatibleResponse))
    }

    func testLoadRejectsUnsupportedHostState() async {
        let result = await load(
            hostBody: #"{"results":[{"attrs":{"acknowledgement":0,"display_name":"Host","downtime_depth":0,"name":"host-1","state":2},"name":"host-1","type":"Host"}]}"#
        )

        XCTAssertEqual(result, .failed(.incompatibleResponse))
    }

    func testLoadRejectsServiceResultWithWrongObjectType() async {
        let result = await load(
            serviceBody: #"{"results":[{"attrs":{"acknowledgement":0,"display_name":"Disk","downtime_depth":0,"host_name":"host-1","name":"disk","state":2},"name":"host-1!disk","type":"Host"}]}"#
        )

        XCTAssertEqual(result, .failed(.incompatibleResponse))
    }

    func testLoadRejectsServiceWithoutHostName() async {
        let result = await load(
            serviceBody: #"{"results":[{"attrs":{"acknowledgement":0,"display_name":"Disk","downtime_depth":0,"name":"disk","state":2},"name":"host-1!disk","type":"Service"}]}"#
        )

        XCTAssertEqual(result, .failed(.incompatibleResponse))
    }

    func testLoadRejectsUnsupportedServiceState() async {
        let result = await load(
            serviceBody: #"{"results":[{"attrs":{"acknowledgement":0,"display_name":"Disk","downtime_depth":0,"host_name":"host-1","name":"disk","state":4},"name":"host-1!disk","type":"Service"}]}"#
        )

        XCTAssertEqual(result, .failed(.incompatibleResponse))
    }

    func testLoadIgnoresHealthyServiceResults() async {
        let result = await load(
            serviceBody: #"{"results":[{"attrs":{"acknowledgement":0,"display_name":"Disk","downtime_depth":0,"host_name":"host-1","name":"disk","state":0},"name":"host-1!disk","type":"Service"}]}"#
        )

        guard case .loaded(let snapshot) = result else {
            return XCTFail("Expected a loaded snapshot, got \(result)")
        }
        XCTAssertEqual(snapshot.issues, [])
    }

    func testLoadRejectsSuccessfulButIncompatiblePayload() async {
        StubURLProtocol.handler = { request in
            Self.response(request: request, statusCode: 200, body: #"{"status":"ok"}"#)
        }

        let result = await loader().load(source(), password: "secret")

        XCTAssertEqual(result, .failed(.incompatibleResponse))
    }

    func testLoadMapsFiveThousandServiceProblemsWithinFiveSeconds() async {
        let issueCount = 5_000
        let serviceResults = (0..<issueCount).map { index in
            let suffix = String(format: "%05d", index)
            return #"{"attrs":{"acknowledgement":0,"display_name":"Service \#(suffix)","downtime_depth":0,"host_name":"host-\#(suffix)","last_check_result":{"output":"CRITICAL"},"name":"service-\#(suffix)","state":2},"name":"host-\#(suffix)!service-\#(suffix)","type":"Service"}"#
        }
        let serviceData = Data("{\"results\":[\(serviceResults.joined(separator: ","))]}".utf8)
        StubURLProtocol.handler = { request in
            let body = request.url?.path.hasSuffix("/services") == true
                ? serviceData
                : Data(#"{"results":[]}"#.utf8)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, body)
        }
        let clock = ContinuousClock()
        let startedAt = clock.now

        let result = await loader().load(source(), password: "secret")

        let elapsed = startedAt.duration(to: clock.now)
        guard case .loaded(let snapshot) = result else {
            return XCTFail("Expected a loaded snapshot, got \(result)")
        }
        XCTAssertEqual(snapshot.issues.count, issueCount)
        XCTAssertEqual(snapshot.actionableIssues.count, issueCount)
        XCTAssertEqual(snapshot.highestAttentionSeverity, .critical)
        XCTAssertEqual(snapshot.issues.first?.displayName, "Service 00000")
        XCTAssertEqual(snapshot.issues.last?.displayName, "Service 04999")
        XCTAssertLessThan(elapsed, .seconds(5))
    }

    private func loader(now: Date = .now) -> Icinga2SnapshotLoader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return Icinga2SnapshotLoader(configuration: configuration, now: { now })
    }

    private func source() -> MonitoringSource {
        MonitoringSource(
            name: "Production",
            providerID: Icinga2Provider.id,
            endpoint: URL(string: "https://icinga.example.test:5665/v1")!,
            authentication: .basic(username: "operator")
        )
    }

    private func load(
        hostBody: String = #"{"results":[]}"#,
        serviceBody: String = #"{"results":[]}"#
    ) async -> SnapshotLoadResult {
        StubURLProtocol.handler = { request in
            Self.response(
                request: request,
                statusCode: 200,
                body: request.url?.path.hasSuffix("/hosts") == true ? hostBody : serviceBody
            )
        }
        return await loader().load(source(), password: "secret")
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

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func append(_ request: URLRequest) {
        lock.lock()
        recorded.append(request)
        lock.unlock()
    }
}
