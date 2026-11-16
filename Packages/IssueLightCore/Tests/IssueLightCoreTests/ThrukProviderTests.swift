import Foundation
import XCTest
@testable import IssueLightCore

final class ThrukProviderTests: XCTestCase {
    private let stubHost = "thruk-\(UUID().uuidString.lowercased()).example.test"

    func testBuiltInRegistryPublishesThrukCapabilities() throws {
        let registry = ProviderRegistry.builtIn()
        let provider = try XCTUnwrap(registry.provider(for: ThrukProvider.id))

        XCTAssertEqual(
            registry.descriptors.map(\.displayName),
            ["Checkmk", "Icinga 2", "Nagios Core", "Thruk"]
        )
        XCTAssertEqual(provider.descriptor.endpointExample, "monitoring.example/thruk")
        XCTAssertEqual(provider.descriptor.capabilities.authenticationMethods, [.basic, .apiKey])
        XCTAssertEqual(
            provider.descriptor.capabilities.serverTrustMethods,
            [.system, .customCertificate, .pinnedCertificate, .disabled]
        )
        XCTAssertEqual(
            provider.descriptor.capabilities.actions,
            [.recheck, .acknowledge, .scheduleDowntime]
        )
    }

    func testWriteActionsRequireAPIKeyAuthentication() {
        let provider = ThrukProvider()
        var configuredSource = source()

        XCTAssertTrue(provider.supportedActions(for: configuredSource).isEmpty)

        configuredSource.authentication = .apiKey(username: "operator")
        XCTAssertEqual(
            provider.supportedActions(for: configuredSource),
            [.recheck, .acknowledge, .scheduleDowntime]
        )
    }

    func testEndpointDiscoveryAcceptsHostAPIAndWebURLs() {
        let provider = ThrukProvider()

        XCTAssertEqual(
            provider.endpointCandidates(from: "monitoring.example.test").map(\.absoluteString),
            ["https://monitoring.example.test/thruk/r/v1"]
        )
        XCTAssertEqual(
            provider.endpointCandidates(
                from: "https://monitoring.example.test:8443/site/thruk/r/v1/hosts?state[gt]=0"
            ).map(\.absoluteString),
            ["https://monitoring.example.test:8443/site/thruk/r/v1"]
        )
        XCTAssertEqual(
            provider.endpointCandidates(
                from: "http://monitoring.example.test/site/thruk/cgi-bin/status.cgi?host=all"
            ).map(\.absoluteString),
            ["http://monitoring.example.test/site/thruk/r/v1"]
        )
    }

    func testEndpointDiscoveryRejectsCredentialsAndUnsupportedSchemes() {
        let provider = ThrukProvider()

        XCTAssertEqual(provider.endpointCandidates(from: "https://user:secret@monitoring.example.test"), [])
        XCTAssertEqual(provider.endpointCandidates(from: "ftp://monitoring.example.test"), [])
    }

    func testProviderValidatesRESTBaseAndAuthentication() {
        let provider = ThrukProvider()
        var source = source(endpoint: "https://\(stubHost)/thruk/r/v1")

        XCTAssertEqual(provider.validate(source), [])

        source.endpoint = URL(string: "https://\(stubHost)/thruk/cgi-bin/status.cgi")!
        XCTAssertEqual(provider.validate(source), [.unsupportedPath("/thruk/cgi-bin/status.cgi")])

        source.endpoint = URL(string: "https://\(stubHost)/thruk/r/v1")!
        source.authentication = .clientCertificate(identityID: "identity")
        XCTAssertEqual(provider.validate(source), [.unsupportedAuthentication(.clientCertificate)])
    }

    func testConnectionConfirmsThrukAndObjectPermissionsWithBasicAuthentication() async {
        let recorder = ThrukRequestRecorder()
        StubURLProtocol.configure(host: stubHost) { request in
            recorder.append(request)
            let body = request.url?.path.hasSuffix("/thruk") == true
                ? #"{"rest_version":"1","thruk_version":"3.20"}"#
                : "[]"
            return Self.response(request: request, statusCode: 200, body: body)
        }
        let provider = ThrukProvider(configuration: configuration())

        let result = await provider.testConnection(
            to: source(),
            access: ProviderAccess(credential: .password("secret"))
        )

        XCTAssertEqual(result, .connected)
        XCTAssertEqual(
            Set(recorder.requests.compactMap { $0.url?.path }),
            ["/thruk/r/v1/thruk", "/thruk/r/v1/hosts", "/thruk/r/v1/services"]
        )
        XCTAssertTrue(recorder.requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Basic b3BlcmF0b3I6c2VjcmV0"
        })
    }

    func testConnectionUsesThrukAPIKeyAndOptionalUserHeaders() async {
        let recorder = ThrukRequestRecorder()
        StubURLProtocol.configure(host: stubHost) { request in
            recorder.append(request)
            let body = request.url?.path.hasSuffix("/thruk") == true
                ? #"{"rest_version":"1"}"#
                : "[]"
            return Self.response(request: request, statusCode: 200, body: body)
        }
        let provider = ThrukProvider(configuration: configuration())
        var apiKeySource = source()
        apiKeySource.authentication = .apiKey(username: "automation")

        let result = await provider.testConnection(
            to: apiKeySource,
            access: ProviderAccess(credential: .apiKey("key-value"))
        )

        XCTAssertEqual(result, .connected)
        XCTAssertTrue(recorder.requests.allSatisfy {
            $0.value(forHTTPHeaderField: "X-Thruk-Auth-Key") == "key-value"
                && $0.value(forHTTPHeaderField: "X-Thruk-Auth-User") == "automation"
                && $0.value(forHTTPHeaderField: "Authorization") == nil
        })
    }

    func testConnectionDistinguishesAuthenticationAuthorizationAndPayloadFailures() async {
        let provider = ThrukProvider(configuration: configuration())
        for (status, body, expected) in [
            (401, #"{"message":"login failed"}"#, ConnectionTestResult.failed(.authentication)),
            (403, #"{"message":"forbidden"}"#, ConnectionTestResult.failed(.authorization)),
            (200, #"{"not":"thruk"}"#, ConnectionTestResult.failed(.incompatibleResponse)),
        ] {
            StubURLProtocol.configure(host: stubHost) { request in
                Self.response(request: request, statusCode: status, body: body)
            }

            let result = await provider.testConnection(
                to: source(),
                access: ProviderAccess(credential: .password("secret"))
            )
            XCTAssertEqual(result, expected)
        }
    }

    func testSnapshotMapsThrukHostAndServiceProblems() async {
        StubURLProtocol.configure(host: stubHost) { request in
            let body: String
            if request.url?.path.hasSuffix("/hosts") == true {
                body = #"[{"acknowledged":0,"current_attempt":2,"display_name":"Edge Router","last_state_change":1799990000,"max_check_attempts":3,"name":"edge-1","peer_key":"prod","plugin_output":"DOWN - no route","scheduled_downtime_depth":0,"state":1}]"#
            } else {
                body = #"[{"acknowledged":1,"current_attempt":1,"description":"Disk /","host_name":"edge-1","last_state_change":1799995000,"max_check_attempts":5,"peer_key":"prod","plugin_output":"WARNING - 85%","scheduled_downtime_depth":1,"state":1}]"#
            }
            return Self.response(request: request, statusCode: 200, body: body)
        }
        let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let provider = ThrukProvider(configuration: configuration(), now: { observedAt })

        let result = await provider.loadSnapshot(
            from: source(),
            access: ProviderAccess(credential: .password("secret"))
        )

        guard case .loaded(let snapshot) = result else {
            return XCTFail("Expected a loaded snapshot, got \(result)")
        }
        XCTAssertEqual(snapshot.observedAt, observedAt)
        XCTAssertEqual(snapshot.issues.count, 2)
        XCTAssertEqual(ThrukObjectIdentifier.backendID(from: snapshot.issues[0].nativeID), "prod")
        XCTAssertEqual(snapshot.issues[0].displayName, "Edge Router")
        XCTAssertEqual(snapshot.issues[0].severity, .critical)
        XCTAssertEqual(snapshot.issues[0].summary, "DOWN - no route")
        XCTAssertEqual(snapshot.issues[0].stateChangedAt, Date(timeIntervalSince1970: 1_799_990_000))
        XCTAssertEqual(snapshot.issues[0].checkAttempt, 2)
        XCTAssertEqual(snapshot.issues[0].maxCheckAttempts, 3)
        XCTAssertFalse(snapshot.issues[0].isAcknowledged)
        XCTAssertFalse(snapshot.issues[0].isInDowntime)
        XCTAssertEqual(ThrukObjectIdentifier.backendID(from: snapshot.issues[1].nativeID), "prod")
        XCTAssertNotEqual(snapshot.issues[0].nativeID, snapshot.issues[1].nativeID)
        XCTAssertEqual(snapshot.issues[1].severity, .warning)
        XCTAssertTrue(snapshot.issues[1].isAcknowledged)
        XCTAssertTrue(snapshot.issues[1].isInDowntime)
    }

    func testSnapshotIgnoresHealthyObjectsAndRejectsMalformedProblems() async {
        let provider = ThrukProvider(configuration: configuration())
        StubURLProtocol.configure(host: stubHost) { request in
            let body = request.url?.path.hasSuffix("/hosts") == true
                ? #"[{"name":"up","state":0}]"#
                : #"[{"host_name":"edge","description":"Broken","state":8}]"#
            return Self.response(request: request, statusCode: 200, body: body)
        }

        let result = await provider.loadSnapshot(
            from: source(),
            access: ProviderAccess(credential: .password("secret"))
        )

        XCTAssertEqual(result, .failed(.incompatibleResponse))
    }

    func testSnapshotRejectsUnknownBooleanValues() async {
        StubURLProtocol.configure(host: stubHost) { request in
            let body = request.url?.path.hasSuffix("/hosts") == true
                ? #"[{"acknowledged":"sometimes","name":"edge-1","state":1}]"#
                : "[]"
            return Self.response(request: request, statusCode: 200, body: body)
        }
        let provider = ThrukProvider(configuration: configuration())

        let result = await provider.loadSnapshot(
            from: source(),
            access: ProviderAccess(credential: .password("secret"))
        )

        XCTAssertEqual(result, .failed(.incompatibleResponse))
    }

    func testSnapshotRejectsFractionalIntegerValues() async {
        StubURLProtocol.configure(host: stubHost) { request in
            let body = request.url?.path.hasSuffix("/hosts") == true
                ? #"[{"name":"edge-1","state":1.5}]"#
                : "[]"
            return Self.response(request: request, statusCode: 200, body: body)
        }
        let provider = ThrukProvider(configuration: configuration())

        let result = await provider.loadSnapshot(
            from: source(),
            access: ProviderAccess(credential: .password("secret"))
        )

        XCTAssertEqual(result, .failed(.incompatibleResponse))
    }

    func testActionsPostDocumentedThrukCommands() async throws {
        let recorder = ThrukRequestRecorder()
        StubURLProtocol.configure(host: stubHost) { request in
            recorder.append(request)
            return Self.response(
                request: request,
                statusCode: 200,
                body: #"{"commands":"COMMAND [1794824682] SCHEDULE_FORCED_SVC_CHECK;edge-1;Disk / root;1794824682","message":"Command successfully submitted"}"#
            )
        }
        let provider = ThrukProvider(configuration: configuration())
        var actionSource = source()
        actionSource.authentication = .apiKey(username: "operator")
        let hostIssue = issue(sourceID: actionSource.id, kind: .host)
        let serviceIssue = issue(sourceID: actionSource.id, kind: .service, serviceName: "Disk / root")

        let recheckResult = await provider.perform(
            .recheck,
            on: serviceIssue,
            from: actionSource,
            access: ProviderAccess(credential: .apiKey("secret"))
        )
        XCTAssertEqual(recheckResult, .completed)
        let acknowledgeResult = await provider.perform(
            .acknowledge(author: "Operator", comment: "Investigating"),
            on: hostIssue,
            from: actionSource,
            access: ProviderAccess(credential: .apiKey("secret"))
        )
        XCTAssertEqual(acknowledgeResult, .completed)
        let downtimeResult = await provider.perform(
            .scheduleDowntime(
                author: "Operator",
                comment: "Maintenance",
                start: Date(timeIntervalSince1970: 1_800_000_000),
                end: Date(timeIntervalSince1970: 1_800_003_600)
            ),
            on: serviceIssue,
            from: actionSource,
            access: ProviderAccess(credential: .apiKey("secret"))
        )
        XCTAssertEqual(downtimeResult, .completed)

        XCTAssertEqual(
            recorder.requests[0].url.flatMap(Self.percentEncodedPath),
            "/thruk/r/v1/sites/prod/services/edge-1/Disk%20%2F%20root/cmd/schedule_forced_svc_check"
        )
        XCTAssertEqual(
            recorder.requests[1].url?.path,
            "/thruk/r/v1/sites/prod/hosts/edge-1/cmd/acknowledge_host_problem"
        )
        let acknowledgement = try XCTUnwrap(
            URLComponents(string: "?" + String(decoding: try Self.bodyData(for: recorder.requests[1]), as: UTF8.self))?.queryItems
        )
        XCTAssertEqual(acknowledgement.first(where: { $0.name == "comment_author" })?.value, "Operator")
        XCTAssertEqual(acknowledgement.first(where: { $0.name == "comment_data" })?.value, "Investigating")
        XCTAssertEqual(
            recorder.requests[2].url.flatMap(Self.percentEncodedPath),
            "/thruk/r/v1/sites/prod/services/edge-1/Disk%20%2F%20root/cmd/schedule_svc_downtime"
        )
        let downtime = try XCTUnwrap(
            URLComponents(string: "?" + String(decoding: try Self.bodyData(for: recorder.requests[2]), as: UTF8.self))?.queryItems
        )
        XCTAssertEqual(downtime.first(where: { $0.name == "start_time" })?.value, "1800000000")
        XCTAssertEqual(downtime.first(where: { $0.name == "end_time" })?.value, "1800003600")
        XCTAssertEqual(downtime.first(where: { $0.name == "fixed" })?.value, "1")
    }

    func testRejectedActionReturnsServerMessage() async {
        StubURLProtocol.configure(host: stubHost) { request in
            Self.response(
                request: request,
                statusCode: 200,
                body: #"{"message":"command permission denied","success":false}"#
            )
        }
        let provider = ThrukProvider(configuration: configuration())
        var actionSource = source()
        actionSource.authentication = .apiKey(username: "operator")

        let result = await provider.perform(
            .recheck,
            on: issue(sourceID: actionSource.id, kind: .host),
            from: actionSource,
            access: ProviderAccess(credential: .apiKey("secret"))
        )

        XCTAssertEqual(result, .rejected("command permission denied"))
    }

    func testRejectedActionReturnsDocumentedCoreErrorDetail() async {
        StubURLProtocol.configure(host: stubHost) { request in
            Self.response(
                request: request,
                statusCode: 200,
                body: #"{"code":400,"error":"Couldn't parse command argument","message":"sending command failed"}"#
            )
        }
        let provider = ThrukProvider(configuration: configuration())
        var actionSource = source()
        actionSource.authentication = .apiKey(username: "operator")

        let result = await provider.perform(
            .recheck,
            on: issue(sourceID: actionSource.id, kind: .host),
            from: actionSource,
            access: ProviderAccess(credential: .apiKey("secret"))
        )

        XCTAssertEqual(result, .rejected("Couldn't parse command argument"))
    }

    func testBasicAuthenticatedCommandRequiresAPIKeyWithoutNetworkAccess() async {
        let recorder = ThrukRequestRecorder()
        StubURLProtocol.configure(host: stubHost) { request in
            recorder.append(request)
            return Self.response(request: request, statusCode: 500, body: #"{}"#)
        }
        let provider = ThrukProvider(configuration: configuration())
        let actionSource = source()

        let result = await provider.perform(
            .recheck,
            on: issue(sourceID: actionSource.id, kind: .host),
            from: actionSource,
            access: ProviderAccess(credential: .password("secret"))
        )

        XCTAssertEqual(
            result,
            .rejected("Thruk write actions require API-key authentication.")
        )
        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func testWebURLsPreserveDeploymentPrefix() {
        let provider = ThrukProvider()
        var configuredSource = source(endpoint: "https://monitoring.example.test/site/thruk/r/v1")
        let hostIssue = issue(sourceID: configuredSource.id, kind: .host)
        let serviceIssue = issue(sourceID: configuredSource.id, kind: .service, serviceName: "Disk /")

        XCTAssertEqual(
            provider.defaultWebBaseURL(for: configuredSource)?.absoluteString,
            "https://monitoring.example.test/site/thruk/cgi-bin"
        )
        XCTAssertEqual(
            provider.webURL(for: hostIssue, from: configuredSource)?.absoluteString,
            "https://monitoring.example.test/site/thruk/cgi-bin/extinfo.cgi?type=1&host=edge-1&backend=prod"
        )
        configuredSource.web = MonitoringWebConfiguration(
            baseURL: URL(string: "https://web.example.test/custom/thruk/cgi-bin")!
        )
        XCTAssertEqual(
            provider.webURL(for: serviceIssue, from: configuredSource)?.absoluteString,
            "https://web.example.test/custom/thruk/cgi-bin/extinfo.cgi?type=2&host=edge-1&service=Disk%20/&backend=prod"
        )
    }

    private func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return configuration
    }

    private func source(
        endpoint: String? = nil,
        id: UUID = UUID()
    ) -> MonitoringSource {
        MonitoringSource(
            id: id,
            name: "Production",
            providerID: ThrukProvider.id,
            endpoint: URL(string: endpoint ?? "https://\(stubHost)/thruk/r/v1")!,
            authentication: .basic(username: "operator")
        )
    }

    private func issue(
        sourceID: UUID,
        kind: MonitoringObjectKind,
        serviceName: String? = nil
    ) -> MonitoringIssue {
        MonitoringIssue(
            sourceID: sourceID,
            nativeID: ThrukObjectIdentifier.encode(
                backendID: "prod",
                hostName: "edge-1",
                serviceName: serviceName
            ),
            kind: kind,
            hostName: "edge-1",
            serviceName: serviceName,
            displayName: serviceName ?? "Edge",
            severity: .critical,
            summary: "Problem",
            isAcknowledged: false,
            isInDowntime: false
        )
    }

    private static func response(
        request: URLRequest,
        statusCode: Int,
        body: String
    ) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!,
            Data(body.utf8)
        )
    }

    private static func percentEncodedPath(_ url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath
    }

    private static func bodyData(for request: URLRequest) throws -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return Data()
        }
        stream.open()
        defer { stream.close() }
        var result = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1_024)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 1_024)
            guard count >= 0 else {
                throw stream.streamError ?? URLError(.cannotDecodeContentData)
            }
            guard count > 0 else { break }
            result.append(buffer, count: count)
        }
        return result
    }
}

private final class ThrukRequestRecorder: @unchecked Sendable {
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
