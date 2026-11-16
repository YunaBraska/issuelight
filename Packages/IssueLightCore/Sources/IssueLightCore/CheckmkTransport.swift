import Foundation
import Security

enum CheckmkTransportError: Error {
    case failure(ConnectionFailure)
}

final class CheckmkTransport {
    private let source: MonitoringSource
    private let authorization: String
    private let httpSession: ProviderHTTPSession

    init(
        source: MonitoringSource,
        credential: ProviderCredential,
        trustedServerCertificate: SecCertificate?,
        configuration: URLSessionConfiguration
    ) throws {
        let issues = CheckmkProvider().validate(source)
        guard issues.isEmpty else {
            throw CheckmkTransportError.failure(.invalidConfiguration(issues))
        }
        guard case .apiKey(let username) = source.authentication,
              case .apiKey(let secret) = credential,
              !username.isEmpty,
              !secret.isEmpty else {
            throw CheckmkTransportError.failure(.authentication)
        }

        self.source = source
        authorization = "Bearer \(username) \(secret)"
        do {
            httpSession = try ProviderHTTPSession(
                source: source,
                authentication: .none,
                trustedServerCertificate: trustedServerCertificate,
                configuration: configuration
            )
        } catch let ProviderHTTPError.failure(failure) {
            throw CheckmkTransportError.failure(failure)
        }
    }

    func request(
        pathComponents: [String],
        method: String = "GET",
        json: Any? = nil
    ) throws -> URLRequest {
        guard var components = URLComponents(url: source.endpoint, resolvingAgainstBaseURL: false) else {
            throw CheckmkTransportError.failure(.incompatibleResponse)
        }
        let allowedPathCharacters = CharacterSet.urlPathAllowed
            .subtracting(CharacterSet(charactersIn: "/"))
        let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let encodedComponents = try pathComponents.map { value in
            guard let encoded = value.addingPercentEncoding(withAllowedCharacters: allowedPathCharacters) else {
                throw CheckmkTransportError.failure(.incompatibleResponse)
            }
            return encoded
        }
        components.percentEncodedPath = "/" + ([basePath] + encodedComponents)
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        components.query = nil
        components.fragment = nil
        guard let url = components.url else {
            throw CheckmkTransportError.failure(.incompatibleResponse)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("IssueLight", forHTTPHeaderField: "User-Agent")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        if let json {
            guard JSONSerialization.isValidJSONObject(json) else {
                throw CheckmkTransportError.failure(.incompatibleResponse)
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    func data(for request: URLRequest) async throws -> Data {
        do {
            return try await httpSession.data(for: request)
        } catch let ProviderHTTPError.failure(failure) {
            throw CheckmkTransportError.failure(failure)
        }
    }

    func response(for request: URLRequest) async throws -> ProviderHTTPResponse {
        do {
            return try await httpSession.response(for: request)
        } catch let ProviderHTTPError.failure(failure) {
            throw CheckmkTransportError.failure(failure)
        }
    }

    func close() {
        httpSession.close()
    }
}
