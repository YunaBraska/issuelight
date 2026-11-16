import Foundation

public struct NagiosCoreProvider: MonitoringProvider {
    public static let id = ProviderID(rawValue: "nagios-core")

    private let configuration: URLSessionConfiguration
    private let now: @Sendable () -> Date

    public let descriptor = ProviderDescriptor(
        id: NagiosCoreProvider.id,
        displayName: "Nagios Core",
        endpointExample: "monitoring.example/nagios",
        capabilities: ProviderCapabilities(
            authenticationMethods: [.basic],
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
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              let hintedScheme = components.scheme?.lowercased(),
              ["http", "https"].contains(hintedScheme) else {
            return []
        }

        let originalParts = components.path.split(separator: "/").map(String.init)
        let pathCandidates: [[String]]
        if let last = originalParts.last, last.lowercased().hasSuffix(".cgi") {
            pathCandidates = [Array(originalParts.dropLast()) + ["statusjson.cgi"]]
        } else if originalParts.contains(where: { $0.lowercased() == "cgi-bin" }) {
            pathCandidates = [originalParts + ["statusjson.cgi"]]
        } else if let last = originalParts.last, last.contains(".") {
            pathCandidates = [Array(originalParts.dropLast()) + ["cgi-bin", "statusjson.cgi"]]
        } else if !originalParts.isEmpty {
            pathCandidates = [originalParts + ["cgi-bin", "statusjson.cgi"]]
        } else {
            pathCandidates = [
                ["nagios", "cgi-bin", "statusjson.cgi"],
                ["cgi-bin", "nagios4", "statusjson.cgi"],
                ["cgi-bin", "nagios", "statusjson.cgi"],
                ["cgi-bin", "statusjson.cgi"],
            ]
        }
        let localHosts = ["localhost", "127.0.0.1", "::1"]
        let schemes = hasExplicitScheme
            ? [hintedScheme]
            : (localHosts.contains(host) ? ["https", "http"] : ["https"])
        components.query = nil
        components.fragment = nil
        var seen = Set<String>()
        return schemes.flatMap { scheme in
            pathCandidates.compactMap { path in
                components.scheme = scheme
                components.path = "/" + path.joined(separator: "/")
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
        if source.endpoint.lastPathComponent.lowercased() != "statusjson.cgi" {
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
            for query in ["programstatus", "hostlist", "servicelist"] {
                var items = [URLQueryItem(name: "query", value: query)]
                if query != "programstatus" {
                    items.append(URLQueryItem(name: "details", value: "true"))
                    items.append(URLQueryItem(name: "count", value: "1"))
                }
                let data = try await transport.data(
                    for: transport.request(queryItems: items)
                )
                let envelope = try JSONDecoder().decode(NagiosResultEnvelope.self, from: data)
                guard envelope.result.cgi == "statusjson.cgi",
                      envelope.result.query == query,
                      envelope.result.typeCode == 0 else {
                    return .failed(.incompatibleResponse)
                }
            }
            return .connected
        } catch let NagiosCoreTransportError.failure(failure) {
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
                for: transport.request(queryItems: Self.hostProblemQuery)
            )
            async let serviceData = transport.data(
                for: transport.request(queryItems: Self.serviceProblemQuery)
            )
            return .loaded(
                try await NagiosCoreSnapshotDecoder().decode(
                    sourceID: source.id,
                    observedAt: now(),
                    hostData: hostData,
                    serviceData: serviceData
                )
            )
        } catch let NagiosCoreTransportError.failure(failure) {
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
        do {
            let command = try NagiosCoreCommand(action: action, issue: issue)
            let transport = try makeTransport(source: source, access: access)
            defer { transport.close() }
            let preparation = try await transport.response(
                for: transport.request(
                    cgiName: "cmd.cgi",
                    queryItems: command.preparationQuery
                )
            )
            if let failure = ProviderHTTPSession.failure(forStatusCode: preparation.statusCode) {
                return .failed(failure)
            }
            let page = try NagiosCoreCommandPage(
                data: preparation.data,
                setCookie: preparation.headerValue("Set-Cookie"),
                referenceDate: now()
            )
            let response = try await transport.response(
                for: transport.request(
                    cgiName: "cmd.cgi",
                    method: "POST",
                    form: try command.form(page: page),
                    cookie: "NagFormId=\(page.formID)"
                )
            )
            if let failure = ProviderHTTPSession.failure(forStatusCode: response.statusCode) {
                return .failed(failure)
            }
            guard let html = String(data: response.data, encoding: .utf8) else {
                return .failed(.incompatibleResponse)
            }
            if html.contains("Your command request was successfully submitted to Nagios for processing.") {
                return .completed
            }
            if html.localizedCaseInsensitiveContains("do not have permission") {
                return .failed(.authorization)
            }
            if html.localizedCaseInsensitiveContains("invalid or missing CSRF cookie") {
                return .rejected("Nagios Core rejected the command token. Test the connection and try again.")
            }
            return .rejected("Nagios Core rejected the command.")
        } catch let NagiosCoreTransportError.failure(failure) {
            return .failed(failure)
        } catch is CancellationError {
            return .failed(.cancelled)
        } catch {
            return .failed(.incompatibleResponse)
        }
    }

    public func defaultWebBaseURL(for source: MonitoringSource) -> URL? {
        guard source.providerID == Self.id,
              var components = URLComponents(url: source.endpoint, resolvingAgainstBaseURL: false),
              components.path.lowercased().hasSuffix("/statusjson.cgi") else {
            return nil
        }
        components.path = String(components.path.dropLast("statusjson.cgi".count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + components.path
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
        components.path = "/" + [basePath, "extinfo.cgi"].filter { !$0.isEmpty }.joined(separator: "/")
        var queryItems = [
            URLQueryItem(name: "type", value: issue.kind == .host ? "1" : "2"),
            URLQueryItem(name: "host", value: issue.hostName),
        ]
        if issue.kind == .service, let serviceName = issue.serviceName {
            queryItems.append(URLQueryItem(name: "service", value: serviceName))
        }
        components.queryItems = queryItems
        components.fragment = nil
        return components.url
    }

    func makeTransport(source: MonitoringSource, access: ProviderAccess) throws -> NagiosCoreTransport {
        try NagiosCoreTransport(
            source: source,
            credential: access.credential,
            trustedServerCertificate: access.trustedServerCertificate,
            configuration: configuration.routed(through: access.socksProxy)
        )
    }

    private static let hostProblemQuery = [
        URLQueryItem(name: "query", value: "hostlist"),
        URLQueryItem(name: "details", value: "true"),
        URLQueryItem(name: "hoststatus", value: "down unreachable"),
    ]

    private static let serviceProblemQuery = [
        URLQueryItem(name: "query", value: "servicelist"),
        URLQueryItem(name: "details", value: "true"),
        URLQueryItem(name: "servicestatus", value: "warning unknown critical"),
    ]
}

struct NagiosCoreCommand {
    let issue: MonitoringIssue
    let action: MonitoringAction
    let type: Int

    init(action: MonitoringAction, issue: MonitoringIssue) throws {
        self.action = action
        self.issue = issue
        switch action {
        case .recheck:
            type = issue.kind == .host ? 96 : 7
        case .acknowledge(let author, let comment):
            guard !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NagiosCoreTransportError.failure(.incompatibleResponse)
            }
            type = issue.kind == .host ? 33 : 34
        case .scheduleDowntime(let author, let comment, let start, let end):
            guard !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  end > start else {
                throw NagiosCoreTransportError.failure(.incompatibleResponse)
            }
            type = issue.kind == .host ? 55 : 56
        }
    }

    var preparationQuery: [URLQueryItem] {
        var values = [
            URLQueryItem(name: "cmd_typ", value: String(type)),
            URLQueryItem(name: "host", value: issue.hostName),
        ]
        if issue.kind == .service, let serviceName = issue.serviceName {
            values.append(URLQueryItem(name: "service", value: serviceName))
        }
        return values
    }

    func form(page: NagiosCoreCommandPage) throws -> [URLQueryItem] {
        var values = preparationQuery + [
            URLQueryItem(name: "cmd_mod", value: "2"),
            URLQueryItem(name: "nagFormId", value: page.formID),
            URLQueryItem(name: "btnSubmit", value: "Commit"),
        ]
        switch action {
        case .recheck:
            guard let startTime = page.startTime else {
                throw NagiosCoreTransportError.failure(.incompatibleResponse)
            }
            values += [
                URLQueryItem(name: "start_time", value: startTime),
                URLQueryItem(name: "force_check", value: "on"),
            ]
        case .acknowledge(let author, let comment):
            values += [
                URLQueryItem(name: "com_author", value: author),
                URLQueryItem(name: "com_data", value: comment),
                URLQueryItem(name: "sticky_ack", value: "on"),
                URLQueryItem(name: "send_notification", value: "on"),
            ]
        case .scheduleDowntime(let author, let comment, let start, let end):
            guard let startTime = page.startTime,
                  let endTime = page.endTime(after: end.timeIntervalSince(start)) else {
                throw NagiosCoreTransportError.failure(.incompatibleResponse)
            }
            values += [
                URLQueryItem(name: "com_author", value: author),
                URLQueryItem(name: "com_data", value: comment),
                URLQueryItem(name: "start_time", value: startTime),
                URLQueryItem(name: "end_time", value: endTime),
                URLQueryItem(name: "fixed", value: "1"),
                URLQueryItem(name: "trigger", value: "0"),
                URLQueryItem(name: "hours", value: "0"),
                URLQueryItem(name: "minutes", value: "0"),
            ]
        }
        return values
    }
}

struct NagiosCoreCommandPage {
    let formID: String
    let startTime: String?
    let wallClock: NagiosCoreWallClock?

    init(data: Data, setCookie: String?, referenceDate: Date) throws {
        guard let html = String(data: data, encoding: .utf8) else {
            throw NagiosCoreTransportError.failure(.incompatibleResponse)
        }
        let cookieValue = setCookie?.split(separator: ";").first(where: {
            $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("nagformid=")
        }).map(String.init)
        let cookieToken = cookieValue?.split(separator: "=", maxSplits: 1).last.map(String.init)
        let htmlToken = Self.inputValue(named: "nagFormId", in: html)
        guard let token = cookieToken ?? htmlToken,
              !token.isEmpty,
              token.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }) else {
            throw NagiosCoreTransportError.failure(.incompatibleResponse)
        }
        formID = token
        startTime = Self.inputValue(named: "start_time", in: html)
        wallClock = startTime.flatMap {
            NagiosCoreWallClock(value: $0, referenceDate: referenceDate)
        }
    }

    func endTime(after duration: TimeInterval) -> String? {
        guard duration > 0 else { return nil }
        return wallClock?.adding(duration)
    }

    static func inputValue(named name: String, in html: String) -> String? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let pattern = "(?i)<input\\b[^>\\r\\n]*\\bname\\s*=\\s*['\"]?\(escapedName)['\"]?[^>\\r\\n]*\\bvalue\\s*=\\s*['\"]([^'\"]*)"
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: html,
                range: NSRange(html.startIndex..<html.endIndex, in: html)
              ),
              let range = Range(match.range(at: 1), in: html) else {
            return nil
        }
        return String(html[range])
    }
}

struct NagiosCoreWallClock {
    let date: Date
    let pattern: String

    init?(value: String, referenceDate: Date) {
        let patterns = ["yyyy-MM-dd HH:mm:ss", "MM-dd-yyyy HH:mm:ss", "dd-MM-yyyy HH:mm:ss"]
        let candidates = patterns.compactMap { pattern -> (Date, String)? in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = pattern
            formatter.isLenient = false
            return formatter.date(from: value).map { ($0, pattern) }
        }
        guard let closest = candidates.min(by: {
            abs($0.0.timeIntervalSince(referenceDate)) < abs($1.0.timeIntervalSince(referenceDate))
        }) else { return nil }
        date = closest.0
        pattern = closest.1
    }

    func adding(_ duration: TimeInterval) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = pattern
        return formatter.string(from: date.addingTimeInterval(duration))
    }
}
