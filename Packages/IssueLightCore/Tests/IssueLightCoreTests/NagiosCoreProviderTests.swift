import Foundation
import XCTest
@testable import IssueLightCore

final class NagiosCoreProviderTests: XCTestCase {
    private let stubHost = "nagios-\(UUID().uuidString.lowercased()).example.test"

    func testBuiltInRegistryPublishesNagiosCoreCapabilities() throws {
        let registry = ProviderRegistry.builtIn()
        let provider = try XCTUnwrap(registry.provider(for: NagiosCoreProvider.id))

        XCTAssertEqual(
            registry.descriptors.map(\.displayName),
            ["Checkmk", "Icinga 2", "Nagios Core", "Thruk"]
        )
        XCTAssertEqual(provider.descriptor.endpointExample, "monitoring.example/nagios")
        XCTAssertEqual(provider.descriptor.capabilities.authenticationMethods, [.basic])
        XCTAssertEqual(
            provider.descriptor.capabilities.actions,
            [.recheck, .acknowledge, .scheduleDowntime]
        )
    }

    func testEndpointDiscoveryHandlesHostsWebPagesAndCommonCGILayouts() {
        let provider = NagiosCoreProvider()

        XCTAssertEqual(
            provider.endpointCandidates(from: "monitoring.example.test").map(\.absoluteString),
            [
                "https://monitoring.example.test/nagios/cgi-bin/statusjson.cgi",
                "https://monitoring.example.test/cgi-bin/nagios4/statusjson.cgi",
                "https://monitoring.example.test/cgi-bin/nagios/statusjson.cgi",
                "https://monitoring.example.test/cgi-bin/statusjson.cgi",
            ]
        )
        XCTAssertEqual(
            provider.endpointCandidates(from: "http://monitoring.example.test:8080/nagios/").map(\.absoluteString),
            ["http://monitoring.example.test:8080/nagios/cgi-bin/statusjson.cgi"]
        )
        XCTAssertEqual(
            provider.endpointCandidates(
                from: "https://monitoring.example.test/cgi-bin/nagios4/status.cgi?host=all"
            ).map(\.absoluteString),
            ["https://monitoring.example.test/cgi-bin/nagios4/statusjson.cgi"]
        )
        XCTAssertEqual(
            provider.endpointCandidates(
                from: "https://monitoring.example.test/nagios/index.php?corewindow=status.cgi"
            ).map(\.absoluteString),
            ["https://monitoring.example.test/nagios/cgi-bin/statusjson.cgi"]
        )
        XCTAssertTrue(
            provider.endpointCandidates(from: "localhost").contains {
                $0.absoluteString == "http://localhost/nagios/cgi-bin/statusjson.cgi"
            }
        )
    }

    func testEndpointDiscoveryRejectsCredentialsAndUnsupportedSchemes() {
        let provider = NagiosCoreProvider()

        XCTAssertTrue(provider.endpointCandidates(from: "https://admin:secret@monitoring.example.test").isEmpty)
        XCTAssertTrue(provider.endpointCandidates(from: "ssh://monitoring.example.test/nagios").isEmpty)
    }

    func testValidationRequiresBasicAuthenticationAndStatusJSONEndpoint() {
        let provider = NagiosCoreProvider()
        var configuredSource = source()

        XCTAssertEqual(provider.validate(configuredSource), [])
        configuredSource.authentication = .apiKey(username: "automation")
        XCTAssertEqual(provider.validate(configuredSource), [.unsupportedAuthentication(.apiKey)])
        configuredSource.authentication = .basic(username: "nagiosadmin")
        configuredSource.endpoint = URL(string: "https://\(stubHost)/nagios/cgi-bin/status.cgi")!
        XCTAssertEqual(provider.validate(configuredSource), [.unsupportedPath("/nagios/cgi-bin/status.cgi")])
    }

    func testConnectionConfirmsProgramHostAndServiceQueries() async throws {
        let recorder = NagiosRequestRecorder()
        StubURLProtocol.configure(host: stubHost) { request in
            recorder.append(request)
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "query" })?.value ?? ""
            return Self.response(
                request: request,
                statusCode: 200,
                body: Self.envelope(query: query, data: query == "hostlist"
                    ? #"{"hostlist":{}}"#
                    : query == "servicelist" ? #"{"servicelist":{}}"# : #"{"programstatus":{}}"#)
            )
        }
        let provider = NagiosCoreProvider(configuration: configuration())

        let result = await provider.testConnection(
            to: source(),
            access: ProviderAccess(credential: .password("welcome"))
        )

        XCTAssertEqual(result, .connected)
        XCTAssertEqual(
            recorder.requests.compactMap {
                URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "query" })?.value
            },
            ["programstatus", "hostlist", "servicelist"]
        )
        XCTAssertTrue(recorder.requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Basic bmFnaW9zYWRtaW46d2VsY29tZQ=="
        })
        XCTAssertEqual(
            URLComponents(url: recorder.requests[1].url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "details" })?.value,
            "true"
        )
    }

    func testConnectionMapsAuthenticationAndRejectsOtherProducts() async {
        let provider = NagiosCoreProvider(configuration: configuration())
        for (status, body, expected) in [
            (401, #"{"error":"unauthorized"}"#, ConnectionTestResult.failed(.authentication)),
            (200, #"{"result":{"cgi":"other.cgi","query":"programstatus","type_code":0,"message":""}}"#, ConnectionTestResult.failed(.incompatibleResponse)),
        ] {
            StubURLProtocol.configure(host: stubHost) { request in
                Self.response(request: request, statusCode: status, body: body)
            }
            let result = await provider.testConnection(
                to: source(),
                access: ProviderAccess(credential: .password("welcome"))
            )
            XCTAssertEqual(result, expected)
        }
    }

    func testSnapshotMapsNagiosHostAndServiceProblems() async throws {
        let recorder = NagiosRequestRecorder()
        StubURLProtocol.configure(host: stubHost) { request in
            recorder.append(request)
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "query" })?.value
            let data = query == "hostlist"
                ? #"{"hostlist":{"edge":{"name":"edge","plugin_output":"DOWN - no route\nDetails","status":4,"last_state_change":1799990000,"current_attempt":2,"max_attempts":3,"problem_has_been_acknowledged":false,"scheduled_downtime_depth":0},"router":{"name":"router","plugin_output":"UNREACHABLE","status":8,"problem_has_been_acknowledged":true,"scheduled_downtime_depth":0}}}"#
                : #"{"servicelist":{"edge":{"Disk /":{"host_name":"edge","description":"Disk /","plugin_output":"WARN - 85%","status":4,"last_state_change":1799995000,"current_attempt":1,"max_attempts":5,"problem_has_been_acknowledged":false,"scheduled_downtime_depth":1},"Clock":{"host_name":"edge","description":"Clock","plugin_output":"UNKNOWN","status":8}},"db":{"Database":{"host_name":"db","description":"Database","plugin_output":"CRITICAL","status":16}}}}"#
            return Self.response(
                request: request,
                statusCode: 200,
                body: Self.envelope(query: query ?? "", data: data)
            )
        }
        let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let provider = NagiosCoreProvider(configuration: configuration(), now: { observedAt })

        let result = await provider.loadSnapshot(
            from: source(),
            access: ProviderAccess(credential: .password("welcome"))
        )

        guard case .loaded(let snapshot) = result else {
            return XCTFail("Expected loaded snapshot, got \(result)")
        }
        XCTAssertEqual(snapshot.observedAt, observedAt)
        XCTAssertEqual(snapshot.issues.count, 5)
        XCTAssertEqual(snapshot.issues.first?.displayName, "edge")
        XCTAssertEqual(snapshot.issues.first?.summary, "DOWN - no route")
        XCTAssertEqual(snapshot.issues.first?.stateChangedAt, Date(timeIntervalSince1970: 1_799_990_000))
        XCTAssertEqual(snapshot.issues.first?.checkAttempt, 2)
        XCTAssertEqual(snapshot.issues.first?.maxCheckAttempts, 3)
        XCTAssertEqual(snapshot.issues.first(where: { $0.serviceName == "Disk /" })?.severity, .warning)
        XCTAssertEqual(snapshot.issues.first(where: { $0.serviceName == "Disk /" })?.isInDowntime, true)
        XCTAssertEqual(snapshot.issues.first(where: { $0.hostName == "router" })?.severity, .unknown)
        XCTAssertEqual(snapshot.issues.first(where: { $0.hostName == "router" })?.isAcknowledged, true)
        XCTAssertEqual(snapshot.issues.first(where: { $0.serviceName == "Database" })?.severity, .critical)

        let queries = recorder.requests.compactMap {
            URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems
        }
        let hostQuery = queries.first {
            $0.contains(where: { $0.name == "query" && $0.value == "hostlist" })
        }
        let serviceQuery = queries.first {
            $0.contains(where: { $0.name == "query" && $0.value == "servicelist" })
        }
        XCTAssertEqual(hostQuery?.first(where: { $0.name == "hoststatus" })?.value, "down unreachable")
        XCTAssertEqual(serviceQuery?.first(where: { $0.name == "servicestatus" })?.value, "warning unknown critical")
    }

    func testSnapshotIgnoresHealthyAndPendingObjectsAndRejectsFailedResults() async {
        let provider = NagiosCoreProvider(configuration: configuration())
        StubURLProtocol.configure(host: stubHost) { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "query" })?.value ?? ""
            let data = query == "hostlist"
                ? #"{"hostlist":{"pending":{"name":"pending","status":1},"up":{"name":"up","status":2}}}"#
                : #"{"servicelist":{"up":{"Pending":{"host_name":"up","description":"Pending","status":1},"OK":{"host_name":"up","description":"OK","status":2}}}}"#
            return Self.response(request: request, statusCode: 200, body: Self.envelope(query: query, data: data))
        }
        let empty = await provider.loadSnapshot(
            from: source(),
            access: ProviderAccess(credential: .password("welcome"))
        )
        guard case .loaded(let snapshot) = empty else {
            return XCTFail("Expected loaded snapshot, got \(empty)")
        }
        XCTAssertTrue(snapshot.issues.isEmpty)

        StubURLProtocol.configure(host: stubHost) { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "query" })?.value ?? ""
            let data = query == "hostlist" ? #"{"hostlist":{}}"# : #"{"servicelist":{}}"#
            return Self.response(
                request: request,
                statusCode: 200,
                body: Self.envelope(query: query, typeCode: 6, data: data)
            )
        }
        let failed = await provider.loadSnapshot(
            from: source(),
            access: ProviderAccess(credential: .password("welcome"))
        )
        XCTAssertEqual(failed, .failed(.incompatibleResponse))
    }

    func testActionsUseCSRFHandshakeAndDocumentedCommandFields() async throws {
        let recorder = NagiosRequestRecorder()
        StubURLProtocol.configure(host: stubHost) { request in
            recorder.append(request)
            if request.httpMethod == "GET" {
                return Self.response(
                    request: request,
                    statusCode: 200,
                    body: #"<INPUT TYPE='hidden' NAME='nagFormId' VALUE='abc123'><INPUT TYPE='TEXT' NAME='start_time' VALUE='11-16-2026 12:00:00'>"#,
                    headers: ["Set-Cookie": "NagFormId=abc123; SameSite=Strict; HttpOnly"]
                )
            }
            return Self.response(
                request: request,
                statusCode: 200,
                body: "<p>Your command request was successfully submitted to Nagios for processing.</p>"
            )
        }
        let referenceDate = ISO8601DateFormatter().date(from: "2026-11-16T12:00:00Z")!
        let provider = NagiosCoreProvider(configuration: configuration(), now: { referenceDate })
        let configuredSource = source()
        let host = issue(sourceID: configuredSource.id, kind: .host)
        let service = issue(sourceID: configuredSource.id, kind: .service, serviceName: "Disk /")
        let access = ProviderAccess(credential: .password("welcome"))

        let recheckResult = await provider.perform(.recheck, on: host, from: configuredSource, access: access)
        let acknowledgementResult = await provider.perform(
            .acknowledge(author: "Operator", comment: "Investigating"),
            on: service,
            from: configuredSource,
            access: access
        )
        let downtimeResult = await provider.perform(
            .scheduleDowntime(
                author: "Operator",
                comment: "Maintenance",
                start: referenceDate,
                end: referenceDate.addingTimeInterval(3_600)
            ),
            on: service,
            from: configuredSource,
            access: access
        )

        XCTAssertEqual(recheckResult, .completed)
        XCTAssertEqual(acknowledgementResult, .completed)
        XCTAssertEqual(downtimeResult, .completed)

        XCTAssertEqual(recorder.requests.count, 6)
        let recheck = try Self.form(recorder.requests[1])
        XCTAssertEqual(recheck["cmd_typ"], "96")
        XCTAssertEqual(recheck["cmd_mod"], "2")
        XCTAssertEqual(recheck["nagFormId"], "abc123")
        XCTAssertEqual(recheck["start_time"], "11-16-2026 12:00:00")
        XCTAssertEqual(recheck["force_check"], "on")
        XCTAssertEqual(recorder.requests[1].value(forHTTPHeaderField: "Cookie"), "NagFormId=abc123")

        let acknowledgement = try Self.form(recorder.requests[3])
        XCTAssertEqual(acknowledgement["cmd_typ"], "34")
        XCTAssertEqual(acknowledgement["service"], "Disk /")
        XCTAssertEqual(acknowledgement["com_author"], "Operator")
        XCTAssertEqual(acknowledgement["com_data"], "Investigating")

        let downtime = try Self.form(recorder.requests[5])
        XCTAssertEqual(downtime["cmd_typ"], "56")
        XCTAssertEqual(downtime["start_time"], "11-16-2026 12:00:00")
        XCTAssertEqual(downtime["end_time"], "11-16-2026 13:00:00")
        XCTAssertEqual(downtime["fixed"], "1")
    }

    func testActionFailuresAreExplicit() async {
        let provider = NagiosCoreProvider(configuration: configuration())
        let configuredSource = source()
        let ownIssue = issue(sourceID: configuredSource.id, kind: .host)
        let access = ProviderAccess(credential: .password("welcome"))

        let foreignIssueResult = await provider.perform(
            .acknowledge(author: "Operator", comment: "Investigating"),
            on: issue(sourceID: UUID(), kind: .host),
            from: configuredSource,
            access: access
        )
        XCTAssertEqual(
            foreignIssueResult,
            .rejected("The issue does not belong to this source.")
        )
        StubURLProtocol.configure(host: stubHost) { request in
            if request.httpMethod == "GET" {
                return Self.response(
                    request: request,
                    statusCode: 200,
                    body: #"<INPUT TYPE='hidden' NAME='nagFormId' VALUE='abc123'>"#,
                    headers: ["Set-Cookie": "NagFormId=abc123; HttpOnly"]
                )
            }
            return Self.response(
                request: request,
                statusCode: 200,
                body: "<p>Error: Invalid or missing CSRF cookie!</p>"
            )
        }
        let rejectedTokenResult = await provider.perform(
            .acknowledge(author: "Operator", comment: "Investigating"),
            on: ownIssue,
            from: configuredSource,
            access: access
        )
        XCTAssertEqual(
            rejectedTokenResult,
            .rejected("Nagios Core rejected the command token. Test the connection and try again.")
        )
    }

    func testWebNavigationUsesClassicNagiosObjectViews() {
        let provider = NagiosCoreProvider()
        var configuredSource = source(endpoint: "https://monitoring.example.test/nagios/cgi-bin/statusjson.cgi")
        let host = issue(sourceID: configuredSource.id, kind: .host)
        let service = issue(sourceID: configuredSource.id, kind: .service, serviceName: "Disk /")

        XCTAssertEqual(
            provider.defaultWebBaseURL(for: configuredSource)?.absoluteString,
            "https://monitoring.example.test/nagios/cgi-bin"
        )
        XCTAssertEqual(
            provider.webURL(for: host, from: configuredSource)?.absoluteString,
            "https://monitoring.example.test/nagios/cgi-bin/extinfo.cgi?type=1&host=edge-1"
        )
        configuredSource.web = MonitoringWebConfiguration(
            baseURL: URL(string: "https://web.example.test/cgi-bin/nagios4")!
        )
        XCTAssertEqual(
            provider.webURL(for: service, from: configuredSource)?.absoluteString,
            "https://web.example.test/cgi-bin/nagios4/extinfo.cgi?type=2&host=edge-1&service=Disk%20/"
        )
    }

    private func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return configuration
    }

    private func source(endpoint: String? = nil, id: UUID = UUID()) -> MonitoringSource {
        MonitoringSource(
            id: id,
            name: "Production",
            providerID: NagiosCoreProvider.id,
            endpoint: URL(string: endpoint ?? "https://\(stubHost)/nagios/cgi-bin/statusjson.cgi")!,
            authentication: .basic(username: "nagiosadmin")
        )
    }

    private func issue(
        sourceID: UUID,
        kind: MonitoringObjectKind,
        serviceName: String? = nil
    ) -> MonitoringIssue {
        MonitoringIssue(
            sourceID: sourceID,
            nativeID: "nagios|edge-1|\(serviceName ?? "")",
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

    private static func envelope(query: String, typeCode: Int = 0, data: String) -> String {
        #"{"result":{"cgi":"statusjson.cgi","query":"\#(query)","type_code":\#(typeCode),"message":""},"data":\#(data)}"#
    }

    private static func response(
        request: URLRequest,
        statusCode: Int,
        body: String,
        headers: [String: String] = ["Content-Type": "application/json"]
    ) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!,
            Data(body.utf8)
        )
    }

    private static func form(_ request: URLRequest) throws -> [String: String] {
        let data = try bodyData(for: request)
        let value = String(decoding: data, as: UTF8.self)
        return Dictionary(uniqueKeysWithValues: (URLComponents(string: "?\(value)")?.queryItems ?? []).map {
            ($0.name, $0.value ?? "")
        })
    }

    private static func bodyData(for request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
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

private final class NagiosRequestRecorder: @unchecked Sendable {
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
