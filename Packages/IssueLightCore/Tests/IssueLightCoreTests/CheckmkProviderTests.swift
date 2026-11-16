import Foundation
import XCTest
@testable import IssueLightCore

final class CheckmkProviderTests: XCTestCase {
    private let stubHost = "checkmk-\(UUID().uuidString.lowercased()).example.test"

    func testBuiltInRegistryPublishesCheckmkCapabilities() throws {
        let registry = ProviderRegistry.builtIn()
        let provider = try XCTUnwrap(registry.provider(for: CheckmkProvider.id))

        XCTAssertEqual(
            registry.descriptors.map(\.displayName),
            ["Checkmk", "Icinga 2", "Nagios Core", "Thruk"]
        )
        XCTAssertEqual(provider.descriptor.endpointExample, "monitoring.example/cmk")
        XCTAssertEqual(provider.descriptor.capabilities.authenticationMethods, [.apiKey])
        XCTAssertEqual(
            provider.descriptor.capabilities.serverTrustMethods,
            [.system, .customCertificate, .pinnedCertificate, .disabled]
        )
        XCTAssertEqual(provider.descriptor.capabilities.actions, [.acknowledge, .scheduleDowntime])
    }

    func testEndpointDiscoveryNormalizesHostWebAndAPIInputs() {
        let provider = CheckmkProvider()

        XCTAssertEqual(
            provider.endpointCandidates(from: "monitoring.example.test").map(\.absoluteString),
            [
                "https://monitoring.example.test/cmk/check_mk/api/v1",
                "https://monitoring.example.test/cmk/check_mk/api/1.0",
                "http://monitoring.example.test/cmk/check_mk/api/v1",
                "http://monitoring.example.test/cmk/check_mk/api/1.0",
            ]
        )
        XCTAssertEqual(
            provider.endpointCandidates(
                from: "http://monitoring.example.test:8080/production/check_mk/view.py?view_name=allhosts"
            ).map(\.absoluteString),
            [
                "http://monitoring.example.test:8080/production/check_mk/api/v1",
                "http://monitoring.example.test:8080/production/check_mk/api/1.0",
            ]
        )
        XCTAssertEqual(
            provider.endpointCandidates(
                from: "https://monitoring.example.test/production/check_mk/api/1.0/domain-types/host/collections/all"
            ).map(\.absoluteString),
            [
                "https://monitoring.example.test/production/check_mk/api/1.0",
                "https://monitoring.example.test/production/check_mk/api/v1",
            ]
        )
        XCTAssertEqual(
            provider.endpointCandidates(from: "monitoring.example.test/edge").first?.absoluteString,
            "https://monitoring.example.test/edge/check_mk/api/v1"
        )
    }

    func testEndpointDiscoveryRejectsEmbeddedCredentialsAndUnsupportedSchemes() {
        let provider = CheckmkProvider()

        XCTAssertTrue(provider.endpointCandidates(from: "https://user:secret@monitoring.example.test").isEmpty)
        XCTAssertTrue(provider.endpointCandidates(from: "ftp://monitoring.example.test/cmk").isEmpty)
        XCTAssertEqual(
            provider.endpointCandidates(from: "//monitoring.example.test/cmk").first?.absoluteString,
            "https://monitoring.example.test/cmk/check_mk/api/v1"
        )
        XCTAssertEqual(
            provider.endpointCandidates(from: "   ").first?.absoluteString,
            "https://localhost/cmk/check_mk/api/v1"
        )
    }

    func testValidationRequiresAutomationUserAndRESTBase() {
        let provider = CheckmkProvider()
        var configuredSource = source()

        XCTAssertEqual(provider.validate(configuredSource), [])

        configuredSource.authentication = .apiKey(username: "")
        XCTAssertEqual(provider.validate(configuredSource), [.emptyUsername])

        configuredSource.authentication = .basic(username: "automation")
        XCTAssertEqual(provider.validate(configuredSource), [.unsupportedAuthentication(.basic)])

        configuredSource.authentication = .apiKey(username: "automation")
        configuredSource.endpoint = URL(string: "https://\(stubHost)/cmk/check_mk/")!
        XCTAssertEqual(provider.validate(configuredSource), [.unsupportedPath("/cmk/check_mk")])
    }

    func testConnectionConfirmsVersionAndMonitoringPermissions() async throws {
        let recorder = CheckmkRequestRecorder()
        StubURLProtocol.configure(host: stubHost) { request in
            recorder.append(request)
            let body: String
            switch request.url?.path {
            case "/cmk/check_mk/api/v1/version":
                body = #"{"site":"cmk","rest_api":{"revision":"1.0.0"},"versions":{"checkmk":"2.5.0"},"edition":"raw","demo":false}"#
            default:
                body = #"{"links":[],"id":"all","domainType":"host","title":"All","value":[]}"#
            }
            return Self.response(request: request, statusCode: 200, body: body)
        }
        let provider = CheckmkProvider(configuration: configuration())

        let result = await provider.testConnection(
            to: source(),
            access: ProviderAccess(credential: .apiKey("automation-secret"))
        )

        XCTAssertEqual(result, .connected)
        XCTAssertEqual(
            recorder.requests.compactMap { $0.url?.path },
            [
                "/cmk/check_mk/api/v1/version",
                "/cmk/check_mk/api/v1/domain-types/host/collections/all",
                "/cmk/check_mk/api/v1/domain-types/service/collections/all",
            ]
        )
        XCTAssertTrue(recorder.requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer automation automation-secret"
        })
        let listBodies = try recorder.requests.dropFirst().map(Self.jsonBody)
        XCTAssertEqual(listBodies[0]["columns"] as? [String], ["name"])
        XCTAssertEqual(listBodies[1]["columns"] as? [String], ["host_name", "description"])
    }

    func testConnectionRejectsWrongProductAndMapsHTTPFailures() async {
        let provider = CheckmkProvider(configuration: configuration())
        for (status, body, expected) in [
            (401, #"{"title":"Unauthorized"}"#, ConnectionTestResult.failed(.authentication)),
            (403, #"{"title":"Forbidden"}"#, ConnectionTestResult.failed(.authorization)),
            (200, #"{"not":"checkmk"}"#, ConnectionTestResult.failed(.incompatibleResponse)),
        ] {
            StubURLProtocol.configure(host: stubHost) { request in
                Self.response(request: request, statusCode: status, body: body)
            }

            let result = await provider.testConnection(
                to: source(),
                access: ProviderAccess(credential: .apiKey("automation-secret"))
            )
            XCTAssertEqual(result, expected)
        }
    }

    func testConnectionRejectsUnreadableCollectionsAndMissingCredentials() async {
        StubURLProtocol.configure(host: stubHost) { request in
            let body = request.url?.path.hasSuffix("/version") == true
                ? #"{"site":"cmk","versions":{"checkmk":"2.5.0"}}"#
                : #"{"value":"not-a-collection"}"#
            return Self.response(request: request, statusCode: 200, body: body)
        }
        let provider = CheckmkProvider(configuration: configuration())

        let unreadable = await provider.testConnection(
            to: source(),
            access: ProviderAccess(credential: .apiKey("automation-secret"))
        )
        let missingSecret = await provider.testConnection(
            to: source(),
            access: ProviderAccess(credential: .password("wrong-type"))
        )
        var invalidSource = source()
        invalidSource.endpoint = URL(string: "https://\(stubHost)/cmk/check_mk")!
        let invalid = await provider.testConnection(
            to: invalidSource,
            access: ProviderAccess(credential: .apiKey("automation-secret"))
        )

        XCTAssertEqual(unreadable, .failed(.incompatibleResponse))
        XCTAssertEqual(missingSecret, .failed(.authentication))
        XCTAssertEqual(invalid, .failed(.invalidConfiguration([.unsupportedPath("/cmk/check_mk")])))
    }

    func testSnapshotMapsCheckmkHostAndServiceProblems() async throws {
        let recorder = CheckmkRequestRecorder()
        StubURLProtocol.configure(host: stubHost) { request in
            recorder.append(request)
            let body: String
            if request.url?.path.contains("/host/") == true {
                body = #"{"links":[],"id":"all","domainType":"host","title":"All hosts","value":[{"domainType":"host","id":"edge-1","title":"edge-1","links":[],"extensions":{"acknowledged":0,"alias":"Edge Router","current_attempt":2,"last_state_change":1799990000,"max_check_attempts":3,"name":"edge-1","plugin_output":"DOWN - no route\nDetails","scheduled_downtime_depth":0,"state":1}}]}"#
            } else {
                body = #"{"links":[],"id":"all","domainType":"service","title":"All services","value":[{"domainType":"service","id":"edge-1-Disk /","title":"Disk /","links":[],"extensions":{"acknowledged":1,"current_attempt":1,"description":"Disk /","host_name":"edge-1","last_state_change":1799995000,"max_check_attempts":5,"plugin_output":"WARN - 85%","scheduled_downtime_depth":1,"state":1}}]}"#
            }
            return Self.response(request: request, statusCode: 200, body: body)
        }
        let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let provider = CheckmkProvider(configuration: configuration(), now: { observedAt })

        let result = await provider.loadSnapshot(
            from: source(),
            access: ProviderAccess(credential: .apiKey("automation-secret"))
        )

        guard case .loaded(let snapshot) = result else {
            return XCTFail("Expected a loaded snapshot, got \(result)")
        }
        XCTAssertEqual(snapshot.observedAt, observedAt)
        XCTAssertEqual(snapshot.issues.count, 2)
        XCTAssertEqual(snapshot.issues[0].displayName, "Edge Router")
        XCTAssertEqual(snapshot.issues[0].severity, .critical)
        XCTAssertEqual(snapshot.issues[0].summary, "DOWN - no route")
        XCTAssertEqual(snapshot.issues[0].stateChangedAt, Date(timeIntervalSince1970: 1_799_990_000))
        XCTAssertEqual(snapshot.issues[0].checkAttempt, 2)
        XCTAssertEqual(snapshot.issues[0].maxCheckAttempts, 3)
        XCTAssertFalse(snapshot.issues[0].isAcknowledged)
        XCTAssertFalse(snapshot.issues[0].isInDowntime)
        XCTAssertEqual(snapshot.issues[1].serviceName, "Disk /")
        XCTAssertEqual(snapshot.issues[1].severity, .warning)
        XCTAssertTrue(snapshot.issues[1].isAcknowledged)
        XCTAssertTrue(snapshot.issues[1].isInDowntime)

        let bodies = try recorder.requests.map(Self.jsonBody)
        XCTAssertEqual(
            bodies.first?["query"] as? [String: String],
            ["op": "!=", "left": "state", "right": "0"]
        )
    }

    func testSnapshotRejectsMalformedProblems() async {
        StubURLProtocol.configure(host: stubHost) { request in
            let body = request.url?.path.contains("/host/") == true
                ? #"{"links":[],"value":[{"domainType":"host","links":[],"extensions":{"state":8,"name":"edge"}}]}"#
                : #"{"links":[],"value":[]}"#
            return Self.response(request: request, statusCode: 200, body: body)
        }
        let provider = CheckmkProvider(configuration: configuration())

        let result = await provider.loadSnapshot(
            from: source(),
            access: ProviderAccess(credential: .apiKey("automation-secret"))
        )

        XCTAssertEqual(result, .failed(.incompatibleResponse))
    }

    func testSnapshotIgnoresHealthyObjectsAndMapsEverySupportedProblemState() async {
        StubURLProtocol.configure(host: stubHost) { request in
            let body: String
            if request.url?.path.contains("/host/") == true {
                body = #"{"value":[{"extensions":{"state":0,"name":"healthy"}},{"extensions":{"state":2,"name":"pending","alias":"","plugin_output":""}},{"extensions":{"state":3,"name":"stale","acknowledged":1}}]}"#
            } else {
                body = #"{"value":[{"extensions":{"state":0,"host_name":"healthy","description":"CPU"}},{"extensions":{"state":2,"host_name":"edge","description":"CPU"}},{"extensions":{"state":3,"host_name":"edge","description":"Clock","scheduled_downtime_depth":1}}]}"#
            }
            return Self.response(request: request, statusCode: 200, body: body)
        }
        let provider = CheckmkProvider(configuration: configuration())

        let result = await provider.loadSnapshot(
            from: source(),
            access: ProviderAccess(credential: .apiKey("automation-secret"))
        )

        guard case .loaded(let snapshot) = result else {
            return XCTFail("Expected a loaded snapshot, got \(result)")
        }
        XCTAssertEqual(snapshot.issues.count, 4)
        XCTAssertEqual(snapshot.issues.map(\.severity), [.critical, .unknown, .unknown, .unknown])
        XCTAssertEqual(snapshot.issues.first?.displayName, "CPU")
        XCTAssertEqual(snapshot.issues.first(where: { $0.hostName == "pending" })?.displayName, "pending")
        XCTAssertEqual(snapshot.issues.first(where: { $0.hostName == "pending" })?.summary, "")
        XCTAssertEqual(snapshot.issues.first(where: { $0.hostName == "stale" })?.isAcknowledged, true)
        XCTAssertEqual(snapshot.issues.first(where: { $0.serviceName == "Clock" })?.isInDowntime, true)
    }

    func testActionsUseDocumentedCheckmkPayloads() async throws {
        let recorder = CheckmkRequestRecorder()
        StubURLProtocol.configure(host: stubHost) { request in
            recorder.append(request)
            return Self.response(request: request, statusCode: 204, body: "")
        }
        let provider = CheckmkProvider(configuration: configuration())
        let configuredSource = source()
        let host = issue(sourceID: configuredSource.id, kind: .host)
        let service = issue(sourceID: configuredSource.id, kind: .service, serviceName: "Disk /")

        let acknowledgementResult = await provider.perform(
            .acknowledge(author: "Operator", comment: "Investigating"),
            on: host,
            from: configuredSource,
            access: ProviderAccess(credential: .apiKey("automation-secret"))
        )
        XCTAssertEqual(acknowledgementResult, .completed)
        let downtimeResult = await provider.perform(
            .scheduleDowntime(
                author: "Operator",
                comment: "Maintenance",
                start: Date(timeIntervalSince1970: 1_800_000_000),
                end: Date(timeIntervalSince1970: 1_800_003_600)
            ),
            on: service,
            from: configuredSource,
            access: ProviderAccess(credential: .apiKey("automation-secret"))
        )
        XCTAssertEqual(downtimeResult, .completed)

        XCTAssertEqual(
            recorder.requests[0].url?.path,
            "/cmk/check_mk/api/v1/domain-types/acknowledge/collections/host"
        )
        let acknowledgement = try Self.jsonBody(recorder.requests[0])
        XCTAssertEqual(acknowledgement["acknowledge_type"] as? String, "host")
        XCTAssertEqual(acknowledgement["host_name"] as? String, "edge-1")
        XCTAssertEqual(acknowledgement["comment"] as? String, "Operator: Investigating")
        XCTAssertEqual(acknowledgement["sticky"] as? Bool, true)

        XCTAssertEqual(
            recorder.requests[1].url?.path,
            "/cmk/check_mk/api/v1/domain-types/downtime/collections/service"
        )
        let downtime = try Self.jsonBody(recorder.requests[1])
        XCTAssertEqual(downtime["downtime_type"] as? String, "service")
        XCTAssertEqual(downtime["service_descriptions"] as? [String], ["Disk /"])
        XCTAssertEqual(downtime["start_time"] as? String, "2027-01-15T08:00:00Z")
        XCTAssertEqual(downtime["end_time"] as? String, "2027-01-15T09:00:00Z")
    }

    func testUnsupportedRecheckAndProblemResponseAreExplicit() async {
        let provider = CheckmkProvider(configuration: configuration())
        let configuredSource = source()
        let host = issue(sourceID: configuredSource.id, kind: .host)

        let recheckResult = await provider.perform(
            .recheck,
            on: host,
            from: configuredSource,
            access: ProviderAccess(credential: .apiKey("automation-secret"))
        )
        XCTAssertEqual(
            recheckResult,
            .rejected("Checkmk does not expose rechecks through its supported REST API.")
        )

        StubURLProtocol.configure(host: stubHost) { request in
            Self.response(
                request: request,
                statusCode: 422,
                body: #"{"title":"Unprocessable Content","detail":"The host is not in a problem state."}"#
            )
        }
        let rejectedResult = await provider.perform(
            .acknowledge(author: "Operator", comment: "Investigating"),
            on: host,
            from: configuredSource,
            access: ProviderAccess(credential: .apiKey("automation-secret"))
        )
        XCTAssertEqual(rejectedResult, .rejected("The host is not in a problem state."))
    }

    func testActionsRejectForeignIssuesInvalidInputAndServerFailures() async {
        let provider = CheckmkProvider(configuration: configuration())
        let configuredSource = source()
        let foreignIssue = issue(sourceID: UUID(), kind: .host)
        let ownIssue = issue(sourceID: configuredSource.id, kind: .host)

        let foreign = await provider.perform(
            .acknowledge(author: "Operator", comment: "Investigating"),
            on: foreignIssue,
            from: configuredSource,
            access: ProviderAccess(credential: .apiKey("automation-secret"))
        )
        let emptyComment = await provider.perform(
            .acknowledge(author: " ", comment: "Investigating"),
            on: ownIssue,
            from: configuredSource,
            access: ProviderAccess(credential: .apiKey("automation-secret"))
        )
        let invalidDowntime = await provider.perform(
            .scheduleDowntime(
                author: "Operator",
                comment: "Maintenance",
                start: Date(timeIntervalSince1970: 100),
                end: Date(timeIntervalSince1970: 100)
            ),
            on: ownIssue,
            from: configuredSource,
            access: ProviderAccess(credential: .apiKey("automation-secret"))
        )
        StubURLProtocol.configure(host: stubHost) { request in
            Self.response(request: request, statusCode: 500, body: #"{"title":"Server error"}"#)
        }
        let serverFailure = await provider.perform(
            .acknowledge(author: "Operator", comment: "Investigating"),
            on: ownIssue,
            from: configuredSource,
            access: ProviderAccess(credential: .apiKey("automation-secret"))
        )

        XCTAssertEqual(foreign, .rejected("The issue does not belong to this source."))
        XCTAssertEqual(emptyComment, .failed(.incompatibleResponse))
        XCTAssertEqual(invalidDowntime, .failed(.incompatibleResponse))
        XCTAssertEqual(serverFailure, .failed(.server(statusCode: 500)))
    }

    func testWebNavigationUsesCheckmkContextViews() {
        let provider = CheckmkProvider()
        var configuredSource = source(endpoint: "https://monitoring.example.test/production/check_mk/api/v1")
        let host = issue(sourceID: configuredSource.id, kind: .host)
        let service = issue(sourceID: configuredSource.id, kind: .service, serviceName: "Disk /")

        XCTAssertEqual(
            provider.defaultWebBaseURL(for: configuredSource)?.absoluteString,
            "https://monitoring.example.test/production/check_mk"
        )
        XCTAssertEqual(
            provider.webURL(for: host, from: configuredSource)?.absoluteString,
            "https://monitoring.example.test/production/check_mk/view.py?view_name=host&host=edge-1"
        )
        configuredSource.web = MonitoringWebConfiguration(
            baseURL: URL(string: "https://web.example.test/central/check_mk")!
        )
        XCTAssertEqual(
            provider.webURL(for: service, from: configuredSource)?.absoluteString,
            "https://web.example.test/central/check_mk/view.py?view_name=service&host=edge-1&service=Disk%20/"
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
            providerID: CheckmkProvider.id,
            endpoint: URL(string: endpoint ?? "https://\(stubHost)/cmk/check_mk/api/v1")!,
            authentication: .apiKey(username: "automation")
        )
    }

    private func issue(
        sourceID: UUID,
        kind: MonitoringObjectKind,
        serviceName: String? = nil
    ) -> MonitoringIssue {
        MonitoringIssue(
            sourceID: sourceID,
            nativeID: "checkmk|edge-1|\(serviceName ?? "")",
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

    private static func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        let data = try bodyData(for: request)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
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

private final class CheckmkRequestRecorder: @unchecked Sendable {
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
