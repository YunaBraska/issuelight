import Foundation

public struct ThrukProvider: MonitoringProvider {
    public static let id = ProviderID(rawValue: "thruk")

    private let configuration: URLSessionConfiguration
    private let now: @Sendable () -> Date

    public let descriptor = ProviderDescriptor(
        id: ThrukProvider.id,
        displayName: "Thruk",
        endpointExample: "monitoring.example/thruk",
        capabilities: ProviderCapabilities(
            authenticationMethods: [.basic, .apiKey],
            serverTrustMethods: [.system, .customCertificate, .pinnedCertificate, .disabled],
            actions: [.recheck, .acknowledge, .scheduleDowntime]
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
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            return []
        }

        let pathParts = components.path.split(separator: "/").map(String.init)
        let thrukIndex = pathParts.firstIndex { $0.lowercased() == "thruk" }
        let deploymentPrefix = thrukIndex.map { Array(pathParts[..<$0]) } ?? []
        components.path = "/" + (deploymentPrefix + ["thruk", "r", "v1"]).joined(separator: "/")
        components.query = nil
        components.fragment = nil
        components.scheme = scheme
        return components.url.map { [$0] } ?? []
    }

    public func validate(_ source: MonitoringSource) -> [SourceValidationIssue] {
        var issues = MonitoringSourceValidator.validateSharedFields(source)
        if !descriptor.capabilities.authenticationMethods.contains(source.authentication.method) {
            issues.append(.unsupportedAuthentication(source.authentication.method))
        }
        let path = URLComponents(url: source.endpoint, resolvingAgainstBaseURL: false)?
            .percentEncodedPath
            .trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        let parts = path.split(separator: "/").map { $0.lowercased() }
        let validSuffixes: [[String]] = [
            ["thruk", "r"],
            ["thruk", "r", "v1"],
        ]
        if !validSuffixes.contains(where: { suffix in
            parts.count >= suffix.count && Array(parts.suffix(suffix.count)) == suffix
        }) {
            issues.append(.unsupportedPath(source.endpoint.path))
        }
        return issues
    }

    public func supportedActions(for source: MonitoringSource) -> Set<MonitoringActionKind> {
        source.authentication.method == .apiKey ? descriptor.capabilities.actions : []
    }

    public func testConnection(
        to source: MonitoringSource,
        access: ProviderAccess
    ) async -> ConnectionTestResult {
        do {
            let transport = try makeTransport(source: source, access: access)
            defer { transport.close() }
            let information = try await transport.data(
                for: transport.request(pathComponents: ["thruk"])
            )
            guard let object = try JSONSerialization.jsonObject(with: information) as? [String: Any],
                  object["rest_version"] != nil else {
                return .failed(.incompatibleResponse)
            }
            for objectType in ["hosts", "services"] {
                let data = try await transport.data(
                    for: transport.request(
                        pathComponents: [objectType],
                        queryItems: [
                            URLQueryItem(name: "columns", value: objectType == "hosts" ? "name" : "host_name,description"),
                            URLQueryItem(name: "limit", value: "1"),
                        ]
                    )
                )
                guard (try JSONSerialization.jsonObject(with: data)) is [Any] else {
                    return .failed(.incompatibleResponse)
                }
            }
            return .connected
        } catch let ThrukTransportError.failure(failure) {
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
                    pathComponents: ["hosts"],
                    queryItems: Self.problemQueryItems(columns: Self.hostColumns)
                )
            )
            async let serviceData = transport.data(
                for: transport.request(
                    pathComponents: ["services"],
                    queryItems: Self.problemQueryItems(columns: Self.serviceColumns)
                )
            )
            return .loaded(
                try await ThrukSnapshotDecoder().decode(
                    sourceID: source.id,
                    observedAt: now(),
                    hostData: hostData,
                    serviceData: serviceData
                )
            )
        } catch let ThrukTransportError.failure(failure) {
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
        guard source.authentication.method == .apiKey else {
            return .rejected("Thruk write actions require API-key authentication.")
        }
        do {
            let transport = try makeTransport(source: source, access: access)
            defer { transport.close() }
            let command = try Self.command(for: action, issue: issue)
            let httpResponse = try await transport.response(
                for: transport.request(
                    pathComponents: command.pathComponents,
                    method: "POST",
                    form: command.form
                )
            )
            let response = try? JSONDecoder().decode(
                ThrukCommandResponse.self,
                from: httpResponse.data
            )
            if let rejection = response?.rejection {
                return .rejected(rejection)
            }
            if let failure = ProviderHTTPSession.failure(forStatusCode: httpResponse.statusCode) {
                return .failed(failure)
            }
            guard response != nil else { return .failed(.incompatibleResponse) }
            return .completed
        } catch let ThrukTransportError.failure(failure) {
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
        guard let thrukIndex = parts.firstIndex(where: { $0.lowercased() == "thruk" }) else {
            return nil
        }
        components.path = "/" + (Array(parts[..<thrukIndex]) + ["thruk", "cgi-bin"])
            .joined(separator: "/")
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
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + components.path + "/extinfo.cgi"
        var queryItems = [
            URLQueryItem(name: "type", value: issue.kind == .host ? "1" : "2"),
            URLQueryItem(name: "host", value: issue.hostName),
        ]
        if issue.kind == .service, let serviceName = issue.serviceName {
            queryItems.append(URLQueryItem(name: "service", value: serviceName))
        }
        if let backendID = ThrukObjectIdentifier.backendID(from: issue.nativeID) {
            queryItems.append(URLQueryItem(name: "backend", value: backendID))
        }
        components.queryItems = queryItems
        components.fragment = nil
        return components.url
    }

    func makeTransport(source: MonitoringSource, access: ProviderAccess) throws -> ThrukTransport {
        try ThrukTransport(
            source: source,
            credential: access.credential,
            trustedServerCertificate: access.trustedServerCertificate,
            configuration: configuration.routed(through: access.socksProxy)
        )
    }

    static func problemQueryItems(columns: [String]) -> [URLQueryItem] {
        [
            URLQueryItem(name: "columns", value: columns.joined(separator: ",")),
            URLQueryItem(name: "state[gt]", value: "0"),
        ]
    }

    static func command(
        for action: MonitoringAction,
        issue: MonitoringIssue
    ) throws -> ThrukCommand {
        var path = ThrukObjectIdentifier.backendID(from: issue.nativeID).map {
            ["sites", $0]
        } ?? []
        path += issue.kind == .host
            ? ["hosts", issue.hostName]
            : ["services", issue.hostName, issue.serviceName ?? ""]
        path.append("cmd")
        var form: [URLQueryItem] = []
        switch action {
        case .recheck:
            path.append(issue.kind == .host ? "schedule_forced_host_check" : "schedule_forced_svc_check")
        case .acknowledge(let author, let comment):
            guard !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ThrukTransportError.failure(.incompatibleResponse)
            }
            path.append(issue.kind == .host ? "acknowledge_host_problem" : "acknowledge_svc_problem")
            form = [
                URLQueryItem(name: "comment_author", value: author),
                URLQueryItem(name: "comment_data", value: comment),
                URLQueryItem(name: "sticky_ack", value: "1"),
                URLQueryItem(name: "send_notification", value: "1"),
                URLQueryItem(name: "persistent_comment", value: "0"),
            ]
        case .scheduleDowntime(let author, let comment, let start, let end):
            guard !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  end > start else {
                throw ThrukTransportError.failure(.incompatibleResponse)
            }
            path.append(issue.kind == .host ? "schedule_host_downtime" : "schedule_svc_downtime")
            form = [
                URLQueryItem(name: "comment_author", value: author),
                URLQueryItem(name: "comment_data", value: comment),
                URLQueryItem(name: "start_time", value: String(Int(start.timeIntervalSince1970))),
                URLQueryItem(name: "end_time", value: String(Int(end.timeIntervalSince1970))),
                URLQueryItem(name: "fixed", value: "1"),
            ]
        }
        return ThrukCommand(pathComponents: path, form: form)
    }

    private static let hostColumns = [
        "acknowledged",
        "current_attempt",
        "display_name",
        "last_state_change",
        "max_check_attempts",
        "name",
        "peer_key",
        "plugin_output",
        "scheduled_downtime_depth",
        "state",
    ]

    private static let serviceColumns = [
        "acknowledged",
        "current_attempt",
        "description",
        "display_name",
        "host_name",
        "last_state_change",
        "max_check_attempts",
        "peer_key",
        "plugin_output",
        "scheduled_downtime_depth",
        "state",
    ]
}

struct ThrukCommand {
    let pathComponents: [String]
    let form: [URLQueryItem]
}

struct ThrukCommandResponse: Decodable {
    let code: Int?
    let description: String?
    let error: String?
    let failed: Bool?
    let message: String
    let success: Bool?

    var rejection: String? {
        guard success == false || failed == true || (code ?? 0) >= 400 || error != nil else {
            return nil
        }
        if let description, !description.isEmpty { return description }
        if let error, !error.isEmpty { return error }
        return message
    }
}
