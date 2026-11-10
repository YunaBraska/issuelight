import Foundation
import XCTest
@testable import IssueLightCore

final class Icinga2SnapshotLoaderTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.handler = nil
        StubURLProtocol.onStart = nil
        StubURLProtocol.blocksRequests = false
        StubURLProtocol.didStopLoading = false
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

    func testLoadRejectsSuccessfulButIncompatiblePayload() async {
        StubURLProtocol.handler = { request in
            Self.response(request: request, statusCode: 200, body: #"{"status":"ok"}"#)
        }

        let result = await loader().load(source(), password: "secret")

        XCTAssertEqual(result, .failed(.incompatibleResponse))
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
