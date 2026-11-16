import Foundation

public struct CheckmkProvider: MonitoringProvider {
    public static let id = ProviderID(rawValue: "checkmk")

    private let configuration: URLSessionConfiguration
    private let now: @Sendable () -> Date

    public let descriptor = ProviderDescriptor(
        id: CheckmkProvider.id,
        displayName: "Checkmk",
        endpointExample: "monitoring.example/cmk",
        capabilities: ProviderCapabilities(
            authenticationMethods: [.apiKey],
            serverTrustMethods: [.system, .customCertificate, .pinnedCertificate, .disabled],
            actions: [.acknowledge, .scheduleDowntime]
        )
    )

    public init() {
        configuration = .ephemeral
        now = { Date() }
    }

    init(
        configuration: URLSessionConfiguration,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.now = now
    }

    public func endpointCandidates(from hint: String) -> [URL] {
        let trimmed = hint.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? "localhost" : trimmed
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

        let pathParts = components.path.split(separator: "/").map(String.init)
        let checkmkIndex = pathParts.firstIndex { $0.lowercased() == "check_mk" }
        let sitePrefix: [String]
        if let checkmkIndex, checkmkIndex > 0 {
            sitePrefix = Array(pathParts[..<checkmkIndex])
        } else if let first = pathParts.first,
                  !["check_mk", "api", "v1", "1.0"].contains(first.lowercased()) {
            sitePrefix = [first]
        } else {
            sitePrefix = ["cmk"]
        }
        let hintedVersion: String? = pathParts.indices.compactMap { index in
            guard pathParts[index].lowercased() == "api",
                  pathParts.indices.contains(index + 1) else { return nil }
            let candidate = pathParts[index + 1].lowercased()
            return ["v1", "1.0"].contains(candidate) ? candidate : nil
        }.first
        let versions = [hintedVersion, "v1", "1.0"].compactMap { $0 }.unique
        let schemes = hasExplicitScheme
            ? [hintedScheme]
            : ["https", "http"]

        components.query = nil
        components.fragment = nil
        var seen = Set<String>()
        return schemes.flatMap { scheme in
            versions.compactMap { version in
                components.scheme = scheme
                components.path = "/" + (sitePrefix + ["check_mk", "api", version]).joined(separator: "/")
                guard let url = components.url,
                      seen.insert(url.absoluteString).inserted else { return nil }
                return url
            }
        }
    }

    public func validate(_ source: MonitoringSource) -> [SourceValidationIssue] {
        var issues = MonitoringSourceValidator.validateSharedFields(source)
        if !descriptor.capabilities.authenticationMethods.contains(source.authentication.method) {
            issues.append(.unsupportedAuthentication(source.authentication.method))
        }
        if case .apiKey(let username) = source.authentication,
           username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !issues.contains(.emptyUsername) {
            issues.append(.emptyUsername)
        }
        let parts = source.endpoint.path.split(separator: "/").map { $0.lowercased() }
        let validSuffixes: [[String]] = [
            ["check_mk", "api", "v1"],
            ["check_mk", "api", "1.0"],
        ]
        if !validSuffixes.contains(where: { suffix in
            parts.count > suffix.count && Array(parts.suffix(suffix.count)) == suffix
        }) {
            issues.append(.unsupportedPath(source.endpoint.path))
        }
        return issues
    }

    public func testConnection(
        to source: MonitoringSource,
        access: ProviderAccess
    ) async -> ConnectionTestResult {
        do {
            let transport = try makeTransport(source: source, access: access)
            defer { transport.close() }
            let versionData = try await transport.data(
                for: transport.request(pathComponents: ["version"])
            )
            guard let version = try? JSONDecoder().decode(CheckmkVersion.self, from: versionData),
                  !version.site.isEmpty,
                  version.versions["checkmk"]?.isEmpty == false else {
                return .failed(.incompatibleResponse)
            }
            for (objectType, columns) in [
                ("host", ["name"]),
                ("service", ["host_name", "description"]),
            ] {
                let data = try await transport.data(
                    for: transport.request(
                        pathComponents: ["domain-types", objectType, "collections", "all"],
                        method: "POST",
                        json: ["columns": columns]
                    )
                )
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      object["value"] is [Any] else {
                    return .failed(.incompatibleResponse)
                }
            }
            return .connected
        } catch let CheckmkTransportError.failure(failure) {
            return .failed(failure)
        } catch is CancellationError {
            return .failed(.cancelled)
        } catch {
            return .failed(.incompatibleResponse)
        }
    }

    public func loadSnapshot(
        from source: MonitoringSource,
        access: ProviderAccess
    ) async -> SnapshotLoadResult {
        do {
            let transport = try makeTransport(source: source, access: access)
            defer { transport.close() }
            async let hostData = transport.data(
                for: transport.request(
                    pathComponents: ["domain-types", "host", "collections", "all"],
                    method: "POST",
                    json: Self.problemQuery(columns: Self.hostColumns)
                )
            )
            async let serviceData = transport.data(
                for: transport.request(
                    pathComponents: ["domain-types", "service", "collections", "all"],
                    method: "POST",
                    json: Self.problemQuery(columns: Self.serviceColumns)
                )
            )
            return .loaded(
                try await CheckmkSnapshotDecoder().decode(
                    sourceID: source.id,
                    observedAt: now(),
                    hostData: hostData,
                    serviceData: serviceData
                )
            )
        } catch let CheckmkTransportError.failure(failure) {
            return .failed(failure)
        } catch is CancellationError {
            return .failed(.cancelled)
        } catch {
            return .failed(.incompatibleResponse)
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
        guard action.kind != .recheck else {
            return .rejected("Checkmk does not expose rechecks through its supported REST API.")
        }
        do {
            let command = try Self.command(for: action, issue: issue)
            let transport = try makeTransport(source: source, access: access)
            defer { transport.close() }
            let response = try await transport.response(
                for: transport.request(
                    pathComponents: command.pathComponents,
                    method: "POST",
                    json: command.body
                )
            )
            if let failure = ProviderHTTPSession.failure(forStatusCode: response.statusCode) {
                if [400, 404, 409, 422].contains(response.statusCode),
                   let problem = try? JSONDecoder().decode(CheckmkProblem.self, from: response.data) {
                    return .rejected(problem.message)
                }
                return .failed(failure)
            }
            return .completed
        } catch let CheckmkTransportError.failure(failure) {
            return .failed(failure)
        } catch is CancellationError {
            return .failed(.cancelled)
        } catch {
            return .failed(.incompatibleResponse)
        }
    }

    public func defaultWebBaseURL(for source: MonitoringSource) -> URL? {
        guard source.providerID == Self.id,
              var components = URLComponents(url: source.endpoint, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let parts = components.path.split(separator: "/").map(String.init)
        guard let checkmkIndex = parts.firstIndex(where: { $0.lowercased() == "check_mk" }) else {
            return nil
        }
        components.path = "/" + Array(parts[...checkmkIndex]).joined(separator: "/")
        components.query = nil
        components.fragment = nil
        return components.url
    }

    public func webURL(for issue: MonitoringIssue, from source: MonitoringSource) -> URL? {
        guard issue.sourceID == source.id,
              let baseURL = source.web?.baseURL ?? defaultWebBaseURL(for: source),
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [basePath, "view.py"].filter { !$0.isEmpty }.joined(separator: "/")
        var queryItems = [
            URLQueryItem(name: "view_name", value: issue.kind == .host ? "host" : "service"),
            URLQueryItem(name: "host", value: issue.hostName),
        ]
        if issue.kind == .service, let serviceName = issue.serviceName {
            queryItems.append(URLQueryItem(name: "service", value: serviceName))
        }
        components.queryItems = queryItems
        components.fragment = nil
        return components.url
    }

    func makeTransport(source: MonitoringSource, access: ProviderAccess) throws -> CheckmkTransport {
        try CheckmkTransport(
            source: source,
            credential: access.credential,
            trustedServerCertificate: access.trustedServerCertificate,
            configuration: configuration.routed(through: access.socksProxy)
        )
    }

    static func problemQuery(columns: [String]) -> [String: Any] {
        [
            "columns": columns,
            "query": ["op": "!=", "left": "state", "right": "0"],
        ]
    }

    static func command(for action: MonitoringAction, issue: MonitoringIssue) throws -> CheckmkCommand {
        let kind = issue.kind == .host ? "host" : "service"
        switch action {
        case .recheck:
            throw CheckmkTransportError.failure(.incompatibleResponse)
        case .acknowledge(let author, let comment):
            var body: [String: Any] = [
                "acknowledge_type": kind,
                "host_name": issue.hostName,
                "comment": try combinedComment(author: author, comment: comment),
                "sticky": true,
                "notify": true,
                "persistent": false,
            ]
            if issue.kind == .service, let serviceName = issue.serviceName {
                body["service_description"] = serviceName
            }
            return CheckmkCommand(
                pathComponents: ["domain-types", "acknowledge", "collections", kind],
                body: body
            )
        case .scheduleDowntime(let author, let comment, let start, let end):
            guard end > start else {
                throw CheckmkTransportError.failure(.incompatibleResponse)
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            var body: [String: Any] = [
                "downtime_type": kind,
                "host_name": issue.hostName,
                "start_time": formatter.string(from: start),
                "end_time": formatter.string(from: end),
                "recur": "fixed",
                "duration": 0,
                "comment": try combinedComment(author: author, comment: comment),
            ]
            if issue.kind == .service, let serviceName = issue.serviceName {
                body["service_descriptions"] = [serviceName]
            }
            return CheckmkCommand(
                pathComponents: ["domain-types", "downtime", "collections", kind],
                body: body
            )
        }
    }

    static func combinedComment(author: String, comment: String) throws -> String {
        let trimmedAuthor = author.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedComment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAuthor.isEmpty, !trimmedComment.isEmpty else {
            throw CheckmkTransportError.failure(.incompatibleResponse)
        }
        return "\(trimmedAuthor): \(trimmedComment)"
    }

    private static let hostColumns = [
        "acknowledged",
        "alias",
        "current_attempt",
        "last_state_change",
        "max_check_attempts",
        "name",
        "plugin_output",
        "scheduled_downtime_depth",
        "state",
    ]

    private static let serviceColumns = [
        "acknowledged",
        "current_attempt",
        "description",
        "host_name",
        "last_state_change",
        "max_check_attempts",
        "plugin_output",
        "scheduled_downtime_depth",
        "state",
    ]
}

struct CheckmkCommand {
    let pathComponents: [String]
    let body: [String: Any]
}

struct CheckmkVersion: Decodable {
    let site: String
    let versions: [String: String]
}

struct CheckmkProblem: Decodable {
    let title: String?
    let detail: String?

    var message: String {
        if let detail, !detail.isEmpty { return detail }
        if let title, !title.isEmpty { return title }
        return "Checkmk rejected the request."
    }
}

private extension Array where Element: Hashable {
    var unique: [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
