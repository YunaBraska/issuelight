import Foundation
import Security

enum NagiosCoreTransportError: Error {
    case failure(ConnectionFailure)
}

final class NagiosCoreTransport {
    private let source: MonitoringSource
    private let httpSession: ProviderHTTPSession

    init(
        source: MonitoringSource,
        credential: ProviderCredential,
        trustedServerCertificate: SecCertificate?,
        configuration: URLSessionConfiguration
    ) throws {
        let issues = NagiosCoreProvider().validate(source)
        guard issues.isEmpty else {
            throw NagiosCoreTransportError.failure(.invalidConfiguration(issues))
        }
        guard case .basic(let username) = source.authentication,
              case .password(let password) = credential,
              !username.isEmpty,
              !password.isEmpty else {
            throw NagiosCoreTransportError.failure(.authentication)
        }
        self.source = source
        do {
            httpSession = try ProviderHTTPSession(
                source: source,
                authentication: .basic(username: username, password: password),
                trustedServerCertificate: trustedServerCertificate,
                configuration: configuration
            )
        } catch let ProviderHTTPError.failure(failure) {
            throw NagiosCoreTransportError.failure(failure)
        }
    }

    func request(
        cgiName: String = "statusjson.cgi",
        queryItems: [URLQueryItem] = [],
        method: String = "GET",
        form: [URLQueryItem] = [],
        cookie: String? = nil
    ) throws -> URLRequest {
        guard var components = URLComponents(url: source.endpoint, resolvingAgainstBaseURL: false) else {
            throw NagiosCoreTransportError.failure(.incompatibleResponse)
        }
        var pathParts = components.percentEncodedPath
            .split(separator: "/")
            .map(String.init)
        guard pathParts.last?.lowercased() == "statusjson.cgi" else {
            throw NagiosCoreTransportError.failure(.incompatibleResponse)
        }
        guard let encodedName = cgiName.addingPercentEncoding(
            withAllowedCharacters: CharacterSet.urlPathAllowed.subtracting(
                CharacterSet(charactersIn: "/")
            )
        ) else {
            throw NagiosCoreTransportError.failure(.incompatibleResponse)
        }
        pathParts[pathParts.count - 1] = encodedName
        components.percentEncodedPath = "/" + pathParts.joined(separator: "/")
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        components.fragment = nil
        guard let url = components.url else {
            throw NagiosCoreTransportError.failure(.incompatibleResponse)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue(
            cgiName == "statusjson.cgi" ? "application/json" : "text/html",
            forHTTPHeaderField: "Accept"
        )
        request.setValue("IssueLight", forHTTPHeaderField: "User-Agent")
        if let cookie {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        if !form.isEmpty {
            var formComponents = URLComponents()
            formComponents.queryItems = form
            request.httpBody = Data((formComponents.percentEncodedQuery ?? "").utf8)
            request.setValue(
                "application/x-www-form-urlencoded; charset=utf-8",
                forHTTPHeaderField: "Content-Type"
            )
        }
        return request
    }

    func data(for request: URLRequest) async throws -> Data {
        do {
            return try await httpSession.data(for: request)
        } catch let ProviderHTTPError.failure(failure) {
            throw NagiosCoreTransportError.failure(failure)
        }
    }

    func response(for request: URLRequest) async throws -> ProviderHTTPResponse {
        do {
            return try await httpSession.response(for: request)
        } catch let ProviderHTTPError.failure(failure) {
            throw NagiosCoreTransportError.failure(failure)
        }
    }

    func close() {
        httpSession.close()
    }
}
