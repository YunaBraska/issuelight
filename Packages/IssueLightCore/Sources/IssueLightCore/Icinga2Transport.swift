import Foundation
import Security

enum Icinga2TransportError: Error {
    case failure(ConnectionFailure)
}

final class Icinga2Transport {
    private let source: MonitoringSource
    private let httpSession: ProviderHTTPSession

    private init(
        source: MonitoringSource,
        authentication: ProviderHTTPAuthentication,
        trustedServerCertificate: SecCertificate?,
        configuration: URLSessionConfiguration
    ) throws {
        self.source = source
        httpSession = try ProviderHTTPSession(
            source: source,
            authentication: authentication,
            trustedServerCertificate: trustedServerCertificate,
            configuration: configuration
        )
    }

    static func basic(
        source: MonitoringSource,
        password: String?,
        trustedServerCertificate: SecCertificate?,
        configuration: URLSessionConfiguration
    ) throws -> Icinga2Transport {
        try validate(source, trustedServerCertificate: trustedServerCertificate)
        guard case .basic(let username) = source.authentication,
              let password,
              !password.isEmpty else {
            throw Icinga2TransportError.failure(.authentication)
        }
        return try Icinga2Transport(
            source: source,
            authentication: .basic(username: username, password: password),
            trustedServerCertificate: trustedServerCertificate,
            configuration: configuration
        )
    }

    static func clientIdentity(
        source: MonitoringSource,
        identity: SecIdentity?,
        trustedServerCertificate: SecCertificate?,
        configuration: URLSessionConfiguration
    ) throws -> Icinga2Transport {
        try validate(source, trustedServerCertificate: trustedServerCertificate)
        guard case .clientCertificate = source.authentication,
              let identity else {
            throw Icinga2TransportError.failure(.clientCertificateNotAvailable)
        }
        return try Icinga2Transport(
            source: source,
            authentication: .clientIdentity(identity),
            trustedServerCertificate: trustedServerCertificate,
            configuration: configuration
        )
    }

    func request(
        objectType: String,
        attributes: [String],
        filter: String? = nil,
        joins: [String] = [],
        limit: Int? = nil
    ) throws -> URLRequest {
        var components = URLComponents(
            url: try Icinga2Provider().statusURL(for: source),
            resolvingAgainstBaseURL: false
        )
        components?.path = "/v1/objects/\(objectType)"
        var queryItems = attributes.map { URLQueryItem(name: "attrs", value: $0) }
        queryItems += joins.map { URLQueryItem(name: "joins", value: $0) }
        if let filter {
            queryItems.append(URLQueryItem(name: "filter", value: filter))
        }
        if let limit {
            queryItems.append(URLQueryItem(name: "limit", value: String(limit)))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else {
            throw Icinga2TransportError.failure(.incompatibleResponse)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("IssueLight", forHTTPHeaderField: "User-Agent")
        return request
    }

    func actionRequest(_ action: MonitoringAction, issue: MonitoringIssue) throws -> URLRequest {
        let actionName: String
        var body: [String: Any] = [
            "type": issue.kind == .host ? "Host" : "Service",
            "filter": try Self.filter(for: issue),
        ]
        switch action {
        case .recheck:
            actionName = "reschedule-check"
            body["force"] = true
        case .acknowledge(let author, let comment):
            guard !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Icinga2TransportError.failure(.incompatibleResponse)
            }
            actionName = "acknowledge-problem"
            body["author"] = author
            body["comment"] = comment
            body["notify"] = true
            body["persistent"] = false
            body["sticky"] = true
        case .scheduleDowntime(let author, let comment, let start, let end):
            guard !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  end > start else {
                throw Icinga2TransportError.failure(.incompatibleResponse)
            }
            actionName = "schedule-downtime"
            body["author"] = author
            body["comment"] = comment
            body["start_time"] = start.timeIntervalSince1970
            body["end_time"] = end.timeIntervalSince1970
            body["fixed"] = true
        }

        var components = URLComponents(
            url: try Icinga2Provider().statusURL(for: source),
            resolvingAgainstBaseURL: false
        )
        components?.path = "/v1/actions/\(actionName)"
        components?.query = nil
        guard let url = components?.url else {
            throw Icinga2TransportError.failure(.incompatibleResponse)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("IssueLight", forHTTPHeaderField: "User-Agent")
        return request
    }

    func data(for request: URLRequest) async throws -> Data {
        do {
            return try await httpSession.data(for: request)
        } catch let ProviderHTTPError.failure(failure) {
            throw Icinga2TransportError.failure(failure)
        }
    }

    func close() {
        httpSession.close()
    }

    private static func validate(
        _ source: MonitoringSource,
        trustedServerCertificate: SecCertificate?
    ) throws {
        let issues = Icinga2Provider().validate(source)
        guard issues.isEmpty else {
            throw Icinga2TransportError.failure(.invalidConfiguration(issues))
        }
        guard source.endpoint.scheme?.lowercased() == "https" else { return }
        switch source.serverTrust {
        case .system, .disabled:
            return
        case .customCertificate:
            guard trustedServerCertificate != nil else {
                throw Icinga2TransportError.failure(.serverCertificateNotAvailable)
            }
        case .pinnedCertificate:
            return
        }
    }

    private static func filter(for issue: MonitoringIssue) throws -> String {
        let host = try jsonString(issue.hostName)
        guard issue.kind == .service, let serviceName = issue.serviceName else {
            return "host.name==\(host)"
        }
        return "host.name==\(host) && service.name==\(try jsonString(serviceName))"
    }

    private static func jsonString(_ value: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes])
        let encoded = String(decoding: data, as: UTF8.self)
        return String(encoded.dropFirst().dropLast())
    }
}
