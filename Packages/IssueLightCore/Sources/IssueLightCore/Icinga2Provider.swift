import Foundation

public struct Icinga2Provider: MonitoringProvider {
    public static let id = ProviderID(rawValue: "icinga2")

    private let connectionTester: Icinga2ConnectionTester
    private let snapshotLoader: Icinga2SnapshotLoader
    private let configuration: URLSessionConfiguration

    public let descriptor = ProviderDescriptor(
        id: Icinga2Provider.id,
        displayName: "Icinga 2",
        capabilities: ProviderCapabilities(
            authenticationMethods: [.basic, .clientCertificate],
            serverTrustMethods: [.system, .customCertificate, .pinnedCertificate, .disabled],
            actions: [.recheck, .acknowledge, .scheduleDowntime]
        )
    )

    public init() {
        configuration = .default
        connectionTester = Icinga2ConnectionTester()
        snapshotLoader = Icinga2SnapshotLoader()
    }

    init(configuration: URLSessionConfiguration, now: @escaping @Sendable () -> Date = { Date() }) {
        self.configuration = configuration
        connectionTester = Icinga2ConnectionTester(configuration: configuration)
        snapshotLoader = Icinga2SnapshotLoader(configuration: configuration, now: now)
    }

    public func validate(_ source: MonitoringSource) -> [SourceValidationIssue] {
        var issues = MonitoringSourceValidator.validateSharedFields(source)
        let components = URLComponents(url: source.endpoint, resolvingAgainstBaseURL: false)

        if components?.scheme?.lowercased() == "http" {
            issues.append(.unsupportedScheme("http"))
        }

        let path = components?.percentEncodedPath ?? ""
        if !["", "/", "/v1", "/v1/"].contains(path) {
            issues.append(.unsupportedPath(path))
        }

        return issues
    }

    public func statusURL(for source: MonitoringSource) throws -> URL {
        let issues = validate(source)
        guard issues.isEmpty else {
            throw Icinga2ProviderError.invalidSource(issues)
        }

        var components = URLComponents(url: source.endpoint, resolvingAgainstBaseURL: false)!
        components.path = "/v1/status"
        components.query = nil
        components.fragment = nil
        return components.url!
    }

    public func webURL(for issue: MonitoringIssue, from source: MonitoringSource) -> URL? {
        guard issue.sourceID == source.id, let baseURL = source.web?.baseURL else {
            return nil
        }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        var path = components?.path
            .split(separator: "/")
            .map(String.init) ?? []
        let usesIcingaDBWeb = path.last?.lowercased() == "icingadb"
        var queryItems: [URLQueryItem]
        if usesIcingaDBWeb {
            path.append(issue.kind == .host ? "host" : "service")
            queryItems = [URLQueryItem(name: issue.kind == .host ? "name" : "host.name", value: issue.hostName)]
            if issue.kind == .service, let serviceName = issue.serviceName {
                queryItems.append(URLQueryItem(name: "name", value: serviceName))
            }
        } else {
            if path.last?.lowercased() != "monitoring" {
                path.append("monitoring")
            }
            path.append(contentsOf: issue.kind == .host ? ["host", "show"] : ["service", "show"])
            queryItems = [URLQueryItem(name: "host", value: issue.hostName)]
            if issue.kind == .service, let serviceName = issue.serviceName {
                queryItems.append(URLQueryItem(name: "service", value: serviceName))
            }
        }
        components?.path = "/" + path.joined(separator: "/")
        components?.queryItems = queryItems
        components?.fragment = nil
        return components?.url
    }

    public func testConnection(
        to source: MonitoringSource,
        access: ProviderAccess
    ) async -> ConnectionTestResult {
        switch (source.authentication, access.credential) {
        case (.basic, .password(let password)):
            return await connectionTester.test(
                source,
                password: password,
                trustedServerCertificate: access.trustedServerCertificate
            )
        case (.clientCertificate, .clientIdentity(let identity)):
            return await connectionTester.test(
                source,
                clientIdentity: identity,
                trustedServerCertificate: access.trustedServerCertificate
            )
        case (.basic, .clientIdentity):
            return .failed(.authentication)
        case (.clientCertificate, .password):
            return .failed(.clientCertificateNotAvailable)
        }
    }

    public func loadSnapshot(
        from source: MonitoringSource,
        access: ProviderAccess
    ) async -> SnapshotLoadResult {
        switch (source.authentication, access.credential) {
        case (.basic, .password(let password)):
            return await snapshotLoader.load(
                source,
                password: password,
                trustedServerCertificate: access.trustedServerCertificate
            )
        case (.clientCertificate, .clientIdentity(let identity)):
            return await snapshotLoader.load(
                source,
                clientIdentity: identity,
                trustedServerCertificate: access.trustedServerCertificate
            )
        case (.basic, .clientIdentity):
            return .failed(.authentication)
        case (.clientCertificate, .password):
            return .failed(.clientCertificateNotAvailable)
        }
    }

    public func perform(
        _ action: MonitoringAction,
        on issue: MonitoringIssue,
        from source: MonitoringSource,
        access: ProviderAccess
    ) async -> MonitoringActionResult {
        guard issue.sourceID == source.id else {
            return .rejected("The issue does not belong to this source.")
        }

        do {
            let transport: Icinga2Transport
            switch (source.authentication, access.credential) {
            case (.basic, .password(let password)):
                transport = try Icinga2Transport.basic(
                    source: source,
                    password: password,
                    trustedServerCertificate: access.trustedServerCertificate,
                    configuration: configuration
                )
            case (.clientCertificate, .clientIdentity(let identity)):
                transport = try Icinga2Transport.clientIdentity(
                    source: source,
                    identity: identity,
                    trustedServerCertificate: access.trustedServerCertificate,
                    configuration: configuration
                )
            case (.basic, .clientIdentity):
                return .failed(.authentication)
            case (.clientCertificate, .password):
                return .failed(.clientCertificateNotAvailable)
            }
            defer { transport.close() }
            let request = try transport.actionRequest(action, issue: issue)
            let data = try await transport.data(for: request)
            return try Self.decodeActionResponse(data)
        } catch let Icinga2TransportError.failure(failure) {
            return .failed(failure)
        } catch {
            return .failed(.incompatibleResponse)
        }
    }

    private static func decodeActionResponse(_ data: Data) throws -> MonitoringActionResult {
        let envelope = try JSONDecoder().decode(IcingaActionEnvelope.self, from: data)
        guard !envelope.results.isEmpty else {
            return .rejected("Icinga did not report an affected object.")
        }
        if let rejected = envelope.results.first(where: { $0.code < 200 || $0.code >= 300 }) {
            return .rejected(rejected.status)
        }
        return .completed
    }
}

private struct IcingaActionEnvelope: Decodable {
    let results: [IcingaActionResult]
}

private struct IcingaActionResult: Decodable {
    let code: Int
    let status: String
}

public enum Icinga2ProviderError: Error, Equatable {
    case invalidSource([SourceValidationIssue])
}
