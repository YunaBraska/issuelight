import Foundation
import Security

enum Icinga2TransportError: Error {
    case failure(ConnectionFailure)
}

final class Icinga2Transport {
    private let source: MonitoringSource
    private let credential: Icinga2RequestCredential
    private let session: URLSession

    private init(
        source: MonitoringSource,
        credential: Icinga2RequestCredential,
        configuration: URLSessionConfiguration
    ) {
        self.source = source
        self.credential = credential
        session = URLSession(
            configuration: configuration,
            delegate: Icinga2SessionDelegate(source: source, credential: credential),
            delegateQueue: nil
        )
    }

    static func basic(
        source: MonitoringSource,
        password: String?,
        configuration: URLSessionConfiguration
    ) throws -> Icinga2Transport {
        try validate(source)
        guard case .basic(let username) = source.authentication,
              let password,
              !password.isEmpty else {
            throw Icinga2TransportError.failure(.authentication)
        }
        return Icinga2Transport(
            source: source,
            credential: .basic(username: username, password: password),
            configuration: configuration
        )
    }

    static func clientIdentity(
        source: MonitoringSource,
        identity: SecIdentity?,
        configuration: URLSessionConfiguration
    ) throws -> Icinga2Transport {
        try validate(source)
        guard case .clientCertificate = source.authentication,
              let identity else {
            throw Icinga2TransportError.failure(.clientCertificateNotAvailable)
        }
        return Icinga2Transport(
            source: source,
            credential: .clientIdentity(identity),
            configuration: configuration
        )
    }

    func request(
        objectType: String,
        attributes: [String],
        filter: String? = nil,
        limit: Int? = nil
    ) throws -> URLRequest {
        var components = URLComponents(
            url: try Icinga2Provider().statusURL(for: source),
            resolvingAgainstBaseURL: false
        )
        components?.path = "/v1/objects/\(objectType)"
        var queryItems = attributes.map { URLQueryItem(name: "attrs", value: $0) }
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
        if case .basic(let username, let password) = credential {
            let token = Data("\(username):\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    func data(for request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw Icinga2TransportError.failure(.incompatibleResponse)
            }
            if let failure = Self.failure(forStatusCode: httpResponse.statusCode) {
                throw Icinga2TransportError.failure(failure)
            }
            return data
        } catch let error as Icinga2TransportError {
            throw error
        } catch {
            throw Icinga2TransportError.failure(Self.failure(for: error))
        }
    }

    func close() {
        session.finishTasksAndInvalidate()
    }

    private static func validate(_ source: MonitoringSource) throws {
        let issues = Icinga2Provider().validate(source)
        guard issues.isEmpty else {
            throw Icinga2TransportError.failure(.invalidConfiguration(issues))
        }
        switch source.serverTrust {
        case .system, .disabled:
            return
        case .customCertificate, .pinnedCertificate:
            throw Icinga2TransportError.failure(.unsupportedTrustConfiguration)
        }
    }

    private static func failure(forStatusCode statusCode: Int) -> ConnectionFailure? {
        switch statusCode {
        case 200...299:
            return nil
        case 401:
            return .authentication
        case 403:
            return .authorization
        case 500...599:
            return .server(statusCode: statusCode)
        default:
            return .http(statusCode: statusCode)
        }
    }

    private static func failure(for error: Error) -> ConnectionFailure {
        let code = (error as? URLError)?.code
        switch code {
        case .cancelled:
            return .cancelled
        case .serverCertificateHasBadDate,
             .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid,
             .clientCertificateRejected,
             .clientCertificateRequired,
             .secureConnectionFailed:
            return .tls
        case .cannotFindHost,
             .cannotConnectToHost,
             .dnsLookupFailed,
             .networkConnectionLost,
             .notConnectedToInternet,
             .timedOut:
            return .unreachable
        default:
            return .unreachable
        }
    }
}

private enum Icinga2RequestCredential {
    case basic(username: String, password: String)
    case clientIdentity(SecIdentity)
}

private final class Icinga2SessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    private let authority: Icinga2Authority
    private let trust: ServerTrustConfiguration
    private let credential: Icinga2RequestCredential

    init(source: MonitoringSource, credential: Icinga2RequestCredential) {
        authority = Icinga2Authority(url: source.endpoint)!
        trust = source.serverTrust
        self.credential = credential
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate,
           authority.matches(challenge.protectionSpace),
           case .clientIdentity(let identity) = credential {
            completionHandler(
                .useCredential,
                URLCredential(identity: identity, certificates: nil, persistence: .forSession)
            )
            return
        }

        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              trust == .disabled,
              authority.matches(challenge.protectionSpace),
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.previousFailureCount == 0,
              authority.matches(challenge.protectionSpace),
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPBasic,
              case .basic(let username, let password) = credential else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        completionHandler(
            .useCredential,
            URLCredential(user: username, password: password, persistence: .forSession)
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              let redirectedAuthority = Icinga2Authority(url: url),
              authority == redirectedAuthority else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

private struct Icinga2Authority: Equatable {
    let scheme: String
    let host: String
    let port: Int

    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased() else {
            return nil
        }
        self.scheme = scheme
        self.host = host
        port = components.port ?? (scheme == "https" ? 443 : 80)
    }

    func matches(_ protectionSpace: URLProtectionSpace) -> Bool {
        scheme == protectionSpace.protocol?.lowercased()
            && host == protectionSpace.host.lowercased()
            && port == protectionSpace.port
    }
}
