import Foundation
import Security

enum ThrukTransportError: Error {
    case failure(ConnectionFailure)
}

final class ThrukTransport {
    private let source: MonitoringSource
    private let apiKey: String?
    private let apiKeyUsername: String?
    private let httpSession: ProviderHTTPSession

    init(
        source: MonitoringSource,
        credential: ProviderCredential,
        trustedServerCertificate: SecCertificate?,
        configuration: URLSessionConfiguration
    ) throws {
        let issues = ThrukProvider().validate(source)
        guard issues.isEmpty else {
            throw ThrukTransportError.failure(.invalidConfiguration(issues))
        }

        let authentication: ProviderHTTPAuthentication
        switch (source.authentication, credential) {
        case (.basic(let username), .password(let password)) where !password.isEmpty:
            authentication = .basic(username: username, password: password)
            apiKey = nil
            apiKeyUsername = nil
        case (.apiKey(let username), .apiKey(let value)) where !value.isEmpty:
            authentication = .none
            apiKey = value
            apiKeyUsername = username.isEmpty ? nil : username
        case (.basic, _):
            throw ThrukTransportError.failure(.authentication)
        case (.apiKey, _):
            throw ThrukTransportError.failure(.authentication)
        case (.clientCertificate, _):
            throw ThrukTransportError.failure(
                .invalidConfiguration([.unsupportedAuthentication(.clientCertificate)])
            )
        }

        self.source = source
        do {
            httpSession = try ProviderHTTPSession(
                source: source,
                authentication: authentication,
                trustedServerCertificate: trustedServerCertificate,
                configuration: configuration
            )
        } catch let ProviderHTTPError.failure(failure) {
            throw ThrukTransportError.failure(failure)
        }
    }

    func request(
        pathComponents: [String],
        queryItems: [URLQueryItem] = [],
        method: String = "GET",
        form: [URLQueryItem] = []
    ) throws -> URLRequest {
        guard var components = URLComponents(url: source.endpoint, resolvingAgainstBaseURL: false) else {
            throw ThrukTransportError.failure(.incompatibleResponse)
        }
        let allowedPathCharacters = CharacterSet.urlPathAllowed
            .subtracting(CharacterSet(charactersIn: "/"))
        let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let encodedComponents = try pathComponents.map { value in
            guard let encoded = value.addingPercentEncoding(withAllowedCharacters: allowedPathCharacters) else {
                throw ThrukTransportError.failure(.incompatibleResponse)
            }
            return encoded
        }
        components.percentEncodedPath = "/" + ([basePath] + encodedComponents)
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        components.fragment = nil
        guard let url = components.url else {
            throw ThrukTransportError.failure(.incompatibleResponse)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("IssueLight", forHTTPHeaderField: "User-Agent")
        if let apiKey {
            request.setValue(apiKey, forHTTPHeaderField: "X-Thruk-Auth-Key")
        }
        if let apiKeyUsername {
            request.setValue(apiKeyUsername, forHTTPHeaderField: "X-Thruk-Auth-User")
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
            throw ThrukTransportError.failure(failure)
        }
    }

    func response(for request: URLRequest) async throws -> ProviderHTTPResponse {
        do {
            return try await httpSession.response(for: request)
        } catch let ProviderHTTPError.failure(failure) {
            throw ThrukTransportError.failure(failure)
        }
    }

    func close() {
        httpSession.close()
    }
}
