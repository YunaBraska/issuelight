import Foundation
import Security
import XCTest
@testable import IssueLightCore

final class Icinga2ProviderTests: XCTestCase {
    private let stubHost = "provider-\(UUID().uuidString.lowercased()).example.test"

    func testBuiltInRegistryPublishesIcingaCapabilities() throws {
        let registry = ProviderRegistry.builtIn()
        let provider = try XCTUnwrap(registry.provider(for: Icinga2Provider.id))

        XCTAssertEqual(registry.descriptors.map(\.displayName), ["Checkmk", "Icinga 2", "Nagios Core", "Thruk"])
        XCTAssertEqual(provider.descriptor.endpointExample, "https://icinga.example:5665")
        XCTAssertEqual(provider.descriptor.capabilities.authenticationMethods, [.basic, .clientCertificate])
        XCTAssertEqual(
            provider.descriptor.capabilities.serverTrustMethods,
            [.system, .customCertificate, .pinnedCertificate, .disabled]
        )
        XCTAssertEqual(
            provider.descriptor.capabilities.actions,
            [.recheck, .acknowledge, .scheduleDowntime]
        )
    }

    func testRegistryRejectsDuplicateProviderIDs() {
        XCTAssertThrowsError(try ProviderRegistry([Icinga2Provider(), Icinga2Provider()])) { error in
            XCTAssertEqual(error as? ProviderRegistryError, .duplicateProvider(Icinga2Provider.id))
        }
    }

    func testProviderDefaultRejectsUnsupportedAction() async {
        let provider = ReadOnlyTestProvider()
        let actionSource = source(endpoint: "https://icinga.example.test:5665")

        let result = await provider.perform(
            .recheck,
            on: issue(sourceID: actionSource.id, kind: .host),
            from: actionSource,
            access: ProviderAccess(credential: .password("secret"))
        )

        XCTAssertEqual(result, .rejected("This provider does not support the requested action."))
    }

    func testProviderDefaultsRemainSafeForReadOnlyImplementations() {
        let provider = ReadOnlyTestProvider()
        let actionSource = source(endpoint: "https://icinga.example.test:5665")
        let actionIssue = issue(sourceID: actionSource.id, kind: .host)

        XCTAssertEqual(
            provider.endpointCandidates(from: "  https://monitoring.example.test/api  "),
            [URL(string: "https://monitoring.example.test/api")!]
        )
        XCTAssertTrue(provider.endpointCandidates(from: "   ").isEmpty)
        XCTAssertTrue(provider.supportedActions(for: actionSource).isEmpty)
        XCTAssertNil(provider.defaultWebBaseURL(for: actionSource))
        XCTAssertNil(provider.webURL(for: actionIssue, from: actionSource))
    }

    func testMonitoringActionsExposeTheirCapabilityKinds() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertEqual(MonitoringAction.recheck.kind, .recheck)
        XCTAssertEqual(
            MonitoringAction.acknowledge(author: "Operator", comment: "Investigating").kind,
            .acknowledge
        )
        XCTAssertEqual(
            MonitoringAction.scheduleDowntime(
                author: "Operator",
                comment: "Maintenance",
                start: start,
                end: start.addingTimeInterval(3_600)
            ).kind,
            .scheduleDowntime
        )
    }

    func testIcingaAcceptsHTTPAndHTTPSButRejectsUnsupportedPaths() {
        let provider = Icinga2Provider()

        XCTAssertTrue(provider.validate(source(endpoint: "http://icinga.example.test:5665/v1")).isEmpty)
        XCTAssertTrue(provider.validate(source(endpoint: "https://icinga.example.test:5665/v1")).isEmpty)
        XCTAssertEqual(
            provider.validate(source(endpoint: "https://icinga.example.test:5665/custom")),
            [.unsupportedPath("/custom")]
        )
    }

    func testIcingaRejectsClientCertificateAuthenticationWithoutTLS() {
        let provider = Icinga2Provider()
        var httpSource = source(endpoint: "http://icinga.example.test:5665")
        httpSource.authentication = .clientCertificate(identityID: "identity")

        XCTAssertEqual(
            provider.validate(httpSource),
            [.unsupportedAuthentication(.clientCertificate)]
        )
    }

    func testIcingaBuildsCanonicalCandidatesFromMinimalAndNoisyHints() {
        let provider = Icinga2Provider()

        XCTAssertEqual(
            provider.endpointCandidates(from: " icinga.example.test/v1/ ").map(\.absoluteString),
            ["https://icinga.example.test:5665"]
        )
        XCTAssertEqual(
            provider.endpointCandidates(from: "http://icinga.example.test:8443/v2/?ignored=yes").map(\.absoluteString),
            [
                "http://icinga.example.test:8443",
                "http://icinga.example.test:5665",
            ]
        )
    }

    func testIcingaDerivesAPICandidatesFromPastedBrowserURLs() {
        let provider = Icinga2Provider()

        XCTAssertEqual(
            provider.endpointCandidates(
                from: "http://localhost:8080/icingadb/hosts#!/icingadb/host?name=down-host"
            ).map(\.absoluteString),
            [
                "https://localhost:5665",
                "http://localhost:5665",
                "http://localhost:8080",
            ]
        )
        XCTAssertEqual(
            provider.endpointCandidates(
                from: "https://monitoring.example.test/icingaweb2/monitoring/list/services?service_problem=1"
            ).map(\.absoluteString),
            [
                "https://monitoring.example.test:5665",
                "https://monitoring.example.test:443",
            ]
        )
        XCTAssertEqual(
            provider.endpointCandidates(from: "//monitoring.example.test/icingaweb2").map(\.absoluteString),
            [
                "https://monitoring.example.test:5665",
                "https://monitoring.example.test:443",
            ]
        )
        XCTAssertEqual(
            provider.endpointCandidates(from: "http://monitoring.example.test:5665/icingaweb2").map(\.absoluteString),
            [
                "https://monitoring.example.test:5665",
                "http://monitoring.example.test:5665",
            ]
        )
    }

    func testIcingaKeepsAnExplicitPortFirstForAPIShapedHints() {
        let provider = Icinga2Provider()

        XCTAssertEqual(
            provider.endpointCandidates(
                from: "https://monitoring.example.test:8443/v1/objects/hosts?attrs=name#ignored"
            ).map(\.absoluteString),
            [
                "https://monitoring.example.test:8443",
                "https://monitoring.example.test:5665",
            ]
        )
    }

    func testIcingaUsesLocalhostCandidatesForAnEmptyHint() {
        XCTAssertEqual(
            Icinga2Provider().endpointCandidates(from: "   ").map(\.absoluteString),
            ["https://localhost:5665"]
        )
    }

    func testIcingaUsesItsAPIPortWhenHTTPSHintDoesNotStateAPort() {
        XCTAssertEqual(
            Icinga2Provider().endpointCandidates(from: "https://icinga.internal").map(\.absoluteString),
            ["https://icinga.internal:5665"]
        )
    }

    func testIcingaPreservesExplicitHTTPWhenNoPortIsGiven() {
        XCTAssertEqual(
            Icinga2Provider().endpointCandidates(from: "http://icinga.internal").map(\.absoluteString),
            ["http://icinga.internal:5665"]
        )
    }

    func testIcingaRejectsEndpointHintsContainingCredentialsOrMissingAHost() {
        let provider = Icinga2Provider()

        XCTAssertEqual(provider.endpointCandidates(from: "https://user:secret@icinga.example.test"), [])
        XCTAssertEqual(provider.endpointCandidates(from: "https:///v1"), [])
        XCTAssertEqual(provider.endpointCandidates(from: "ftp://icinga.example.test"), [])
    }

    func testIcingaBuildsStatusURLFromRootAndVersionedEndpoint() throws {
        let provider = Icinga2Provider()

        XCTAssertEqual(
            try provider.statusURL(for: source(endpoint: "https://icinga.example.test:5665")),
            URL(string: "https://icinga.example.test:5665/v1/status")
        )
        XCTAssertEqual(
            try provider.statusURL(for: source(endpoint: "https://icinga.example.test:5665/v1/")),
            URL(string: "https://icinga.example.test:5665/v1/status")
        )
        XCTAssertEqual(
            try provider.statusURL(for: source(endpoint: "http://icinga.example.test:5665/v1/")),
            URL(string: "http://icinga.example.test:5665/v1/status")
        )
    }

    func testIcingaBuildsHostAndServiceWebURLsFromConfiguredBase() throws {
        let provider = Icinga2Provider()
        var configuredSource = source(endpoint: "https://icinga.example.test:5665")
        configuredSource.web = MonitoringWebConfiguration(
            baseURL: URL(string: "https://monitoring.example.test/icingaweb2/")!
        )

        XCTAssertEqual(
            provider.webURL(
                for: issue(sourceID: configuredSource.id, kind: .host),
                from: configuredSource
            )?.absoluteString,
            "https://monitoring.example.test/icingaweb2/monitoring/host/show?host=edge-1"
        )
        XCTAssertEqual(
            provider.webURL(
                for: issue(sourceID: configuredSource.id, kind: .service, serviceName: "Disk /"),
                from: configuredSource
            )?.absoluteString,
            "https://monitoring.example.test/icingaweb2/monitoring/service/show?host=edge-1&service=Disk%20/"
        )
    }

    func testIcingaBuildsIcingaDBWebHostAndServiceURLsWhenModulePathIsConfigured() throws {
        let provider = Icinga2Provider()
        var configuredSource = source(endpoint: "https://icinga.example.test:5665")
        configuredSource.web = MonitoringWebConfiguration(
            baseURL: URL(string: "https://monitoring.example.test/icingaweb2/icingadb")!
        )

        XCTAssertEqual(
            provider.webURL(
                for: issue(sourceID: configuredSource.id, kind: .host),
                from: configuredSource
            )?.absoluteString,
            "https://monitoring.example.test/icingaweb2/icingadb/host?name=edge-1"
        )
        XCTAssertEqual(
            provider.webURL(
                for: issue(sourceID: configuredSource.id, kind: .service, serviceName: "HTTP TLS"),
                from: configuredSource
            )?.absoluteString,
            "https://monitoring.example.test/icingaweb2/icingadb/service?host.name=edge-1&name=HTTP%20TLS"
        )
    }

    func testIcingaUsesSameHostIcingaDBWebDefaultWhenNoOverrideExists() {
        let provider = Icinga2Provider()
        var configuredSource = source(endpoint: "https://icinga.example.test:5665")
        let sourceIssue = issue(sourceID: configuredSource.id, kind: .host)

        XCTAssertEqual(
            provider.webURL(for: sourceIssue, from: configuredSource)?.absoluteString,
            "https://icinga.example.test/icingaweb2/icingadb/host?name=edge-1"
        )

        configuredSource.web = MonitoringWebConfiguration(
            baseURL: URL(string: "https://monitoring.example.test/icingaweb2")!
        )
        XCTAssertNil(
            provider.webURL(
                for: issue(sourceID: UUID(), kind: .host),
                from: configuredSource
            )
        )
    }

    func testIcingaDoesNotProvideAWebDefaultForAnotherProvider() {
        let provider = Icinga2Provider()
        var otherSource = source(endpoint: "https://icinga.example.test:5665")
        otherSource.providerID = ProviderID(rawValue: "other")

        XCTAssertNil(provider.defaultWebBaseURL(for: otherSource))
    }

    func testIcingaRejectsStatusURLForInvalidSource() {
        let provider = Icinga2Provider()
        let invalidSource = source(endpoint: "http://icinga.example.test:5665/custom")

        XCTAssertThrowsError(try provider.statusURL(for: invalidSource)) { error in
            XCTAssertEqual(
                error as? Icinga2ProviderError,
                .invalidSource([.unsupportedPath("/custom")])
            )
        }
    }

    func testRegisteredProviderTestsBasicConnection() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        StubURLProtocol.configure(host: stubHost) { request in
            XCTAssertEqual(request.url?.scheme, "http")
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"results":[]}"#.utf8)
            )
        }
        let provider = Icinga2Provider(configuration: configuration)

        let result = await provider.testConnection(
            to: source(endpoint: "http://\(stubHost):5665"),
            access: ProviderAccess(credential: .password("secret"))
        )

        XCTAssertEqual(result, .connected)
    }

    func testRegisteredProviderTestsClientCertificateConnection() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        StubURLProtocol.configure(host: stubHost) { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"results":[]}"#.utf8)
            )
        }
        let provider = Icinga2Provider(configuration: configuration)
        let identity = try await generatedIdentity()
        var clientCertificateSource = source(endpoint: "https://\(stubHost):5665")
        clientCertificateSource.authentication = .clientCertificate(identityID: "identity")

        let result = await provider.testConnection(
            to: clientCertificateSource,
            access: ProviderAccess(credential: .clientIdentity(identity))
        )

        XCTAssertEqual(result, .connected)
    }

    func testRegisteredProviderConnectionRejectsClientIdentityForBasicSource() async throws {
        let provider = Icinga2Provider()
        let identity = try await generatedIdentity()

        let result = await provider.testConnection(
            to: source(endpoint: "https://icinga.example.test:5665"),
            access: ProviderAccess(credential: .clientIdentity(identity))
        )

        XCTAssertEqual(result, .failed(.authentication))
    }

    func testRegisteredProviderConnectionRejectsPasswordForClientCertificateSource() async {
        let provider = Icinga2Provider()
        var clientCertificateSource = source(endpoint: "https://icinga.example.test:5665")
        clientCertificateSource.authentication = .clientCertificate(identityID: "identity")
        let access = ProviderAccess(credential: .password("not-an-identity"))

        let connection = await provider.testConnection(to: clientCertificateSource, access: access)

        XCTAssertEqual(connection, .failed(.clientCertificateNotAvailable))
    }

    func testRegisteredProviderSnapshotRejectsPasswordForClientCertificateSource() async {
        let provider = Icinga2Provider()
        var clientCertificateSource = source(endpoint: "https://icinga.example.test:5665")
        clientCertificateSource.authentication = .clientCertificate(identityID: "identity")
        let access = ProviderAccess(credential: .password("not-an-identity"))

        let snapshot = await provider.loadSnapshot(from: clientCertificateSource, access: access)

        XCTAssertEqual(snapshot, .failed(.clientCertificateNotAvailable))
    }

    func testRegisteredProviderLoadsProviderNeutralSnapshot() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        StubURLProtocol.configure(host: stubHost) { request in
            let body = request.url?.path.hasSuffix("/hosts") == true
                ? #"{"results":[{"attrs":{"acknowledgement":0,"display_name":"Edge","downtime_depth":0,"name":"edge-1","state":1},"name":"edge-1","type":"Host"}]}"#
                : #"{"results":[]}"#
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(body.utf8)
            )
        }
        let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let registry = try ProviderRegistry([
            Icinga2Provider(configuration: configuration, now: { observedAt }),
        ])
        let provider = try XCTUnwrap(registry.provider(for: Icinga2Provider.id))

        let result = await provider.loadSnapshot(
            from: source(endpoint: "https://\(stubHost):5665"),
            access: ProviderAccess(credential: .password("secret"))
        )

        guard case .loaded(let snapshot) = result else {
            return XCTFail("Expected provider snapshot, got \(result)")
        }
        XCTAssertEqual(snapshot.observedAt, observedAt)
        XCTAssertEqual(snapshot.issues.map(\.displayName), ["Edge"])
    }

    func testRegisteredProviderLoadsSnapshotWithClientCertificate() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        StubURLProtocol.configure(host: stubHost) { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"results":[]}"#.utf8)
            )
        }
        let provider = Icinga2Provider(configuration: configuration)
        let identity = try await generatedIdentity()
        var clientCertificateSource = source(endpoint: "https://\(stubHost):5665")
        clientCertificateSource.authentication = .clientCertificate(identityID: "identity")

        let result = await provider.loadSnapshot(
            from: clientCertificateSource,
            access: ProviderAccess(credential: .clientIdentity(identity))
        )

        guard case .loaded(let snapshot) = result else {
            return XCTFail("Expected provider snapshot, got \(result)")
        }
        XCTAssertTrue(snapshot.issues.isEmpty)
    }

    func testRegisteredProviderSnapshotRejectsClientIdentityForBasicSource() async throws {
        let provider = Icinga2Provider()
        let identity = try await generatedIdentity()

        let result = await provider.loadSnapshot(
            from: source(endpoint: "https://icinga.example.test:5665"),
            access: ProviderAccess(credential: .clientIdentity(identity))
        )

        XCTAssertEqual(result, .failed(.authentication))
    }

    func testRegisteredProviderPostsServiceRecheck() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        StubURLProtocol.configure(host: stubHost) { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/actions/reschedule-check")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let body = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: request.bodyData()) as? [String: Any]
            )
            XCTAssertEqual(body["type"] as? String, "Service")
            XCTAssertEqual(body["filter"] as? String, #"host.name=="edge-1" && service.name=="Disk / root""#)
            XCTAssertEqual(body["force"] as? Bool, true)
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"results":[{"code":200,"status":"Successfully rescheduled check."}]}"#.utf8)
            )
        }
        let provider = Icinga2Provider(configuration: configuration)
        let actionSource = source(endpoint: "https://\(stubHost):5665")

        let result = await provider.perform(
            .recheck,
            on: issue(sourceID: actionSource.id, kind: .service, serviceName: "Disk / root"),
            from: actionSource,
            access: ProviderAccess(credential: .password("secret"))
        )

        XCTAssertEqual(result, .completed)
    }

    func testRegisteredProviderPostsActionWithClientCertificate() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        StubURLProtocol.configure(host: stubHost) { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"results":[{"code":200,"status":"Successfully rescheduled check."}]}"#.utf8)
            )
        }
        let provider = Icinga2Provider(configuration: configuration)
        let identity = try await generatedIdentity()
        var actionSource = source(endpoint: "https://\(stubHost):5665")
        actionSource.authentication = .clientCertificate(identityID: "identity")

        let result = await provider.perform(
            .recheck,
            on: issue(sourceID: actionSource.id, kind: .host),
            from: actionSource,
            access: ProviderAccess(credential: .clientIdentity(identity))
        )

        XCTAssertEqual(result, .completed)
    }

    func testRegisteredProviderPostsAcknowledgementAndReportsIcingaRejection() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        StubURLProtocol.configure(host: stubHost) { request in
            XCTAssertEqual(request.url?.path, "/v1/actions/acknowledge-problem")
            let body = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: request.bodyData()) as? [String: Any]
            )
            XCTAssertEqual(body["author"] as? String, "Operator")
            XCTAssertEqual(body["comment"] as? String, "Investigating")
            XCTAssertEqual(body["sticky"] as? Bool, true)
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"results":[{"code":404,"status":"No objects found."}]}"#.utf8)
            )
        }
        let provider = Icinga2Provider(configuration: configuration)
        let actionSource = source(endpoint: "https://\(stubHost):5665")

        let result = await provider.perform(
            .acknowledge(author: "Operator", comment: "Investigating"),
            on: issue(sourceID: actionSource.id, kind: .host),
            from: actionSource,
            access: ProviderAccess(credential: .password("secret"))
        )

        XCTAssertEqual(result, .rejected("No objects found."))
    }

    func testRegisteredProviderPostsFixedDowntime() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        StubURLProtocol.configure(host: stubHost) { request in
            XCTAssertEqual(request.url?.path, "/v1/actions/schedule-downtime")
            let body = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: request.bodyData()) as? [String: Any]
            )
            XCTAssertEqual(body["start_time"] as? Double, 1_800_000_000)
            XCTAssertEqual(body["end_time"] as? Double, 1_800_003_600)
            XCTAssertEqual(body["fixed"] as? Bool, true)
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"results":[{"code":200,"status":"Successfully scheduled downtime."}]}"#.utf8)
            )
        }
        let provider = Icinga2Provider(configuration: configuration)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let actionSource = source(endpoint: "https://\(stubHost):5665")

        let result = await provider.perform(
            .scheduleDowntime(
                author: "Operator",
                comment: "Maintenance",
                start: start,
                end: start.addingTimeInterval(3_600)
            ),
            on: issue(sourceID: actionSource.id, kind: .host),
            from: actionSource,
            access: ProviderAccess(credential: .password("secret"))
        )

        XCTAssertEqual(result, .completed)
    }

    func testRegisteredProviderRejectsActionForAnotherSource() async {
        let provider = Icinga2Provider()
        let actionSource = source(endpoint: "https://icinga.example.test:5665")

        let result = await provider.perform(
            .recheck,
            on: issue(sourceID: UUID(), kind: .host),
            from: actionSource,
            access: ProviderAccess(credential: .password("secret"))
        )

        XCTAssertEqual(result, .rejected("The issue does not belong to this source."))
    }

    func testRegisteredProviderRejectsPasswordForClientCertificateAction() async {
        let provider = Icinga2Provider()
        var actionSource = source(endpoint: "https://icinga.example.test:5665")
        actionSource.authentication = .clientCertificate(identityID: "identity")

        let result = await provider.perform(
            .recheck,
            on: issue(sourceID: actionSource.id, kind: .host),
            from: actionSource,
            access: ProviderAccess(credential: .password("not-an-identity"))
        )

        XCTAssertEqual(result, .failed(.clientCertificateNotAvailable))
    }

    func testRegisteredProviderRejectsBlankAcknowledgementFields() async {
        let provider = Icinga2Provider()
        let actionSource = source(endpoint: "https://icinga.example.test:5665")

        let result = await provider.perform(
            .acknowledge(author: " ", comment: "Investigating"),
            on: issue(sourceID: actionSource.id, kind: .host),
            from: actionSource,
            access: ProviderAccess(credential: .password("secret"))
        )

        XCTAssertEqual(result, .failed(.incompatibleResponse))
    }

    func testRegisteredProviderRejectsBlankAcknowledgementComment() async {
        let provider = Icinga2Provider()
        let actionSource = source(endpoint: "https://icinga.example.test:5665")

        let result = await provider.perform(
            .acknowledge(author: "Operator", comment: " "),
            on: issue(sourceID: actionSource.id, kind: .host),
            from: actionSource,
            access: ProviderAccess(credential: .password("secret"))
        )

        XCTAssertEqual(result, .failed(.incompatibleResponse))
    }

    func testRegisteredProviderRejectsInvalidDowntimeRange() async {
        let provider = Icinga2Provider()
        let actionSource = source(endpoint: "https://icinga.example.test:5665")
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        let result = await provider.perform(
            .scheduleDowntime(
                author: "Operator",
                comment: "Maintenance",
                start: start,
                end: start
            ),
            on: issue(sourceID: actionSource.id, kind: .host),
            from: actionSource,
            access: ProviderAccess(credential: .password("secret"))
        )

        XCTAssertEqual(result, .failed(.incompatibleResponse))
    }

    func testRegisteredProviderRejectsBlankDowntimeAuthor() async {
        let provider = Icinga2Provider()
        let actionSource = source(endpoint: "https://icinga.example.test:5665")
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        let result = await provider.perform(
            .scheduleDowntime(
                author: " ",
                comment: "Maintenance",
                start: start,
                end: start.addingTimeInterval(3_600)
            ),
            on: issue(sourceID: actionSource.id, kind: .host),
            from: actionSource,
            access: ProviderAccess(credential: .password("secret"))
        )

        XCTAssertEqual(result, .failed(.incompatibleResponse))
    }

    func testRegisteredProviderRejectsBlankDowntimeComment() async {
        let provider = Icinga2Provider()
        let actionSource = source(endpoint: "https://icinga.example.test:5665")
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        let result = await provider.perform(
            .scheduleDowntime(
                author: "Operator",
                comment: " ",
                start: start,
                end: start.addingTimeInterval(3_600)
            ),
            on: issue(sourceID: actionSource.id, kind: .host),
            from: actionSource,
            access: ProviderAccess(credential: .password("secret"))
        )

        XCTAssertEqual(result, .failed(.incompatibleResponse))
    }

    func testRegisteredProviderActionRejectsClientIdentityForBasicSource() async throws {
        let provider = Icinga2Provider()
        let identity = try await generatedIdentity()
        let actionSource = source(endpoint: "https://icinga.example.test:5665")

        let result = await provider.perform(
            .recheck,
            on: issue(sourceID: actionSource.id, kind: .host),
            from: actionSource,
            access: ProviderAccess(credential: .clientIdentity(identity))
        )

        XCTAssertEqual(result, .failed(.authentication))
    }

    func testRegisteredProviderMapsActionAuthenticationFailure() async {
        let provider = actionProvider(statusCode: 401, body: #"{"error":"unauthorized"}"#)
        let actionSource = source(endpoint: "https://\(stubHost):5665")

        let result = await provider.perform(
            .recheck,
            on: issue(sourceID: actionSource.id, kind: .host),
            from: actionSource,
            access: ProviderAccess(credential: .password("wrong"))
        )

        XCTAssertEqual(result, .failed(.authentication))
    }

    func testRegisteredProviderRejectsMalformedActionResponse() async {
        let provider = actionProvider(statusCode: 200, body: "not json")
        let actionSource = source(endpoint: "https://\(stubHost):5665")

        let result = await provider.perform(
            .recheck,
            on: issue(sourceID: actionSource.id, kind: .host),
            from: actionSource,
            access: ProviderAccess(credential: .password("secret"))
        )

        XCTAssertEqual(result, .failed(.incompatibleResponse))
    }

    func testRegisteredProviderRejectsActionResponseWithoutAffectedObjects() async {
        let provider = actionProvider(statusCode: 200, body: #"{"results":[]}"#)
        let actionSource = source(endpoint: "https://\(stubHost):5665")

        let result = await provider.perform(
            .recheck,
            on: issue(sourceID: actionSource.id, kind: .host),
            from: actionSource,
            access: ProviderAccess(credential: .password("secret"))
        )

        XCTAssertEqual(result, .rejected("Icinga did not report an affected object."))
    }

    func testRegisteredProviderRejectsActionFromInvalidSource() async {
        let provider = Icinga2Provider()
        let actionSource = source(endpoint: "http://icinga.example.test:5665/custom")

        let result = await provider.perform(
            .recheck,
            on: issue(sourceID: actionSource.id, kind: .host),
            from: actionSource,
            access: ProviderAccess(credential: .password("secret"))
        )

        XCTAssertEqual(result, .failed(.invalidConfiguration([.unsupportedPath("/custom")])))
    }

    private func actionProvider(statusCode: Int, body: String) -> Icinga2Provider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        StubURLProtocol.configure(host: stubHost) { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!,
                Data(body.utf8)
            )
        }
        return Icinga2Provider(configuration: configuration)
    }

    private func generatedIdentity() async throws -> SecIdentity {
        let keychain = try TemporaryTestKeychain()
        addTeardownBlock { try? keychain.delete() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("issuelight-provider-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let keyURL = directory.appendingPathComponent("identity.key")
        let certificateURL = directory.appendingPathComponent("identity.crt")
        let identityURL = directory.appendingPathComponent("identity.p12")
        let password = "temporary-test-password"
        try runOpenSSL([
            "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", keyURL.path,
            "-out", certificateURL.path,
            "-days", "1",
            "-subj", "/CN=IssueLight Provider Test",
        ])
        try runOpenSSL([
            "pkcs12", "-export",
            "-inkey", keyURL.path,
            "-in", certificateURL.path,
            "-out", identityURL.path,
            "-passout", "pass:\(password)",
        ])
        let catalog = KeychainIdentityCatalog(accessContext: keychain.context)
        let descriptor = try await catalog.importPKCS12(at: identityURL, password: password)
        let identity = try await catalog.identity(id: descriptor.id)
        return try XCTUnwrap(identity)
    }

    private func runOpenSSL(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func source(endpoint: String) -> MonitoringSource {
        MonitoringSource(
            name: "Icinga",
            providerID: Icinga2Provider.id,
            endpoint: URL(string: endpoint)!,
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
            nativeID: serviceName.map { "edge-1!\($0)" } ?? "edge-1",
            kind: kind,
            hostName: "edge-1",
            serviceName: serviceName,
            displayName: serviceName ?? "Edge",
            severity: .critical,
            summary: "CRITICAL",
            isAcknowledged: false,
            isInDowntime: false
        )
    }
}

private struct ReadOnlyTestProvider: MonitoringProvider {
    let descriptor = ProviderDescriptor(
        id: ProviderID(rawValue: "read-only-test"),
        displayName: "Read-only test provider",
        capabilities: ProviderCapabilities(
            authenticationMethods: [.basic],
            serverTrustMethods: [.system]
        )
    )

    func validate(_ source: MonitoringSource) -> [SourceValidationIssue] {
        []
    }

    func testConnection(
        to source: MonitoringSource,
        access: ProviderAccess
    ) async -> ConnectionTestResult {
        .connected
    }

    func loadSnapshot(
        from source: MonitoringSource,
        access: ProviderAccess
    ) async -> SnapshotLoadResult {
        .failed(.incompatibleResponse)
    }
}

private extension URLRequest {
    func bodyData() throws -> Data {
        if let httpBody {
            return httpBody
        }
        let stream = try XCTUnwrap(httpBodyStream)
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 {
                throw try XCTUnwrap(stream.streamError)
            }
            if count == 0 {
                break
            }
            data.append(buffer, count: count)
        }
        return data
    }
}
