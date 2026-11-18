import Foundation

public struct Icinga2Provider: MonitoringProvider {
    public static let id = ProviderID(rawValue: "icinga2")

    private let configuration: URLSessionConfiguration
    private let now: @Sendable () -> Date

    public let descriptor = ProviderDescriptor(
        id: Icinga2Provider.id,
        displayName: "Icinga 2",
        endpointExample: "https://icinga.example:5665",
        capabilities: ProviderCapabilities(
            authenticationMethods: [.basic, .clientCertificate],
            serverTrustMethods: [.system, .customCertificate, .pinnedCertificate, .disabled],
            actions: [.recheck, .acknowledge, .scheduleDowntime]
        )
    )

    public init() {
        configuration = .ephemeral
        now = { Date() }
    }

    init(configuration: URLSessionConfiguration, now: @escaping @Sendable () -> Date = { Date() }) {
        self.configuration = configuration
        self.now = now
    }

    public func endpointCandidates(from hint: String) -> [URL] {
        let trimmedHint = hint.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmedHint.isEmpty ? "localhost" : trimmedHint
        let hasExplicitScheme = value.hasPrefix("//") || value.contains("://")
        let valueWithScheme: String
        if value.hasPrefix("//") {
            valueWithScheme = "https:\(value)"
        } else if value.contains("://") {
            valueWithScheme = value
        } else {
            valueWithScheme = "https://\(value)"
        }
        guard var components = URLComponents(string: valueWithScheme),
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              let hintedScheme = components.scheme?.lowercased(),
              ["http", "https"].contains(hintedScheme) else {
            return []
        }

        let explicitPort = components.port
        let hintedPort = explicitPort ?? (hasExplicitScheme && hintedScheme == "https" ? 443 : nil)
        let firstPathComponent = components.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .first?
            .lowercased()
        let looksLikeAPIPath = firstPathComponent == nil
            || firstPathComponent == "v1"
            || firstPathComponent == "v2"
        components.scheme = "https"
        components.path = ""
        components.query = nil
        components.fragment = nil

        var ports: [Int] = []
        if let hintedPort, looksLikeAPIPath {
            ports.append(hintedPort)
        }
        ports.append(5_665)
        if let hintedPort, !looksLikeAPIPath {
            ports.append(hintedPort)
        }

        var seen = Set<String>()
        return ports.compactMap { port in
            components.port = port
            guard let url = components.url,
                  seen.insert(url.absoluteString).inserted else {
                return nil
            }
            return url
        }
    }

    public func validate(_ source: MonitoringSource) -> [SourceValidationIssue] {
        var issues = MonitoringSourceValidator.validateSharedFields(
            source,
            capabilities: descriptor.capabilities
        )
        let components = URLComponents(url: source.endpoint, resolvingAgainstBaseURL: false)

        if !descriptor.capabilities.authenticationMethods.contains(source.authentication.method) {
            issues.append(.unsupportedAuthentication(source.authentication.method))
        }

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

    public func defaultWebBaseURL(for source: MonitoringSource) -> URL? {
        guard source.providerID == Self.id,
              var components = URLComponents(url: source.endpoint, resolvingAgainstBaseURL: false),
              components.host?.isEmpty == false else {
            return nil
        }
        components.user = nil
        components.password = nil
        components.port = nil
        components.path = "/icingaweb2/icingadb"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    public func webURL(for issue: MonitoringIssue, from source: MonitoringSource) -> URL? {
        guard issue.sourceID == source.id,
              let baseURL = source.web?.baseURL ?? defaultWebBaseURL(for: source) else {
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
        let connectionTester = Icinga2ConnectionTester(configuration: sessionConfiguration(for: access))
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
        case (.basic, .clientIdentity), (.basic, .apiKey):
            return .failed(.authentication)
        case (.clientCertificate, .password), (.clientCertificate, .apiKey):
            return .failed(.clientCertificateNotAvailable)
        case (.apiKey, _):
            return .failed(.invalidConfiguration([.unsupportedAuthentication(.apiKey)]))
        }
    }

    public func loadSnapshot(
        from source: MonitoringSource,
        access: ProviderAccess
    ) async -> SnapshotLoadResult {
        let snapshotLoader = Icinga2SnapshotLoader(
            configuration: sessionConfiguration(for: access),
            now: now
        )
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
        case (.basic, .clientIdentity), (.basic, .apiKey):
            return .failed(.authentication)
        case (.clientCertificate, .password), (.clientCertificate, .apiKey):
            return .failed(.clientCertificateNotAvailable)
        case (.apiKey, _):
            return .failed(.invalidConfiguration([.unsupportedAuthentication(.apiKey)]))
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
                    configuration: sessionConfiguration(for: access)
                )
            case (.clientCertificate, .clientIdentity(let identity)):
                transport = try Icinga2Transport.clientIdentity(
                    source: source,
                    identity: identity,
                    trustedServerCertificate: access.trustedServerCertificate,
                    configuration: sessionConfiguration(for: access)
                )
            case (.basic, .clientIdentity), (.basic, .apiKey):
                return .failed(.authentication)
            case (.clientCertificate, .password), (.clientCertificate, .apiKey):
                return .failed(.clientCertificateNotAvailable)
            case (.apiKey, _):
                return .failed(.invalidConfiguration([.unsupportedAuthentication(.apiKey)]))
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

    private func sessionConfiguration(for access: ProviderAccess) -> URLSessionConfiguration {
        configuration.routed(through: access.socksProxy)
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
