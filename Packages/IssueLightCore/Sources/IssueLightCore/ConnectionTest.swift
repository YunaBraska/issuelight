import Foundation
import Security

public enum ConnectionFailure: Error, Equatable, Sendable {
    case invalidConfiguration([SourceValidationIssue])
    case unsupportedTrustConfiguration
    case clientCertificateNotAvailable
    case cancelled
    case unreachable
    case tls
    case authentication
    case authorization
    case incompatibleResponse
    case server(statusCode: Int)
    case http(statusCode: Int)
}

public enum ConnectionTestResult: Equatable, Sendable {
    case connected
    case failed(ConnectionFailure)
}

public final class Icinga2ConnectionTester: @unchecked Sendable {
    private let configuration: URLSessionConfiguration

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
    }

    public func test(_ source: MonitoringSource, password: String?) async -> ConnectionTestResult {
        await test(source, credential: .basic(password))
    }

    public func test(_ source: MonitoringSource, clientIdentity: SecIdentity?) async -> ConnectionTestResult {
        await test(source, credential: .clientIdentity(clientIdentity))
    }

    private func test(_ source: MonitoringSource, credential: ConnectionCredential) async -> ConnectionTestResult {
        let provider = Icinga2Provider()
        let issues = provider.validate(source)
        guard issues.isEmpty else {
            return .failed(.invalidConfiguration(issues))
        }

        switch source.serverTrust {
        case .system, .disabled:
            break
        case .customCertificate, .pinnedCertificate:
            return .failed(.unsupportedTrustConfiguration)
        }

        let requestCredential: RequestCredential
        switch (source.authentication, credential) {
        case (.basic(let username), .basic(let password?)):
            requestCredential = .basic(username: username, password: password)
        case (.basic, .basic(nil)):
            return .failed(.authentication)
        case (.clientCertificate, .clientIdentity(let identity?)):
            requestCredential = .clientIdentity(identity)
        case (.clientCertificate, .clientIdentity(nil)):
            return .failed(.clientCertificateNotAvailable)
        default:
            return .failed(.authentication)
        }

        let delegate = ConnectionSessionDelegate(source: source, credential: requestCredential)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        for objectType in ["hosts", "services"] {
            let request: URLRequest
            do {
                request = try makeRequest(
                    source: source,
                    objectType: objectType,
                    credential: requestCredential
                )
            } catch let error as Icinga2ProviderError {
                switch error {
                case .invalidSource(let issues):
                    return .failed(.invalidConfiguration(issues))
                }
            } catch {
                return .failed(.incompatibleResponse)
            }

            do {
                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    return .failed(.incompatibleResponse)
                }

                if let failure = failure(forStatusCode: httpResponse.statusCode) {
                    return .failed(failure)
                }

                guard responseContainsIcingaResults(data) else {
                    return .failed(.incompatibleResponse)
                }
            } catch {
                return .failed(failure(for: error))
            }
        }

        return .connected
    }

    private func makeRequest(
        source: MonitoringSource,
        objectType: String,
        credential: RequestCredential
    ) throws -> URLRequest {
        var components = URLComponents(url: try Icinga2Provider().statusURL(for: source), resolvingAgainstBaseURL: false)!
        components.path = "/v1/objects/\(objectType)"
        components.queryItems = [
            URLQueryItem(name: "attrs", value: "name"),
            URLQueryItem(name: "limit", value: "1"),
        ]

        var request = URLRequest(url: components.url!)
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

    private func responseContainsIcingaResults(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return object["results"] is [Any]
    }

    private func failure(forStatusCode statusCode: Int) -> ConnectionFailure? {
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

    private func failure(for error: Error) -> ConnectionFailure {
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

private enum ConnectionCredential {
    case basic(String?)
    case clientIdentity(SecIdentity?)
}

private enum RequestCredential {
    case basic(username: String, password: String)
    case clientIdentity(SecIdentity)
}

private final class ConnectionSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    private let authority: ConnectionAuthority
    private let trust: ServerTrustConfiguration
    private let credential: RequestCredential

    init(source: MonitoringSource, credential: RequestCredential) {
        authority = ConnectionAuthority(url: source.endpoint)!
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
              let redirectedAuthority = ConnectionAuthority(url: url),
              authority == redirectedAuthority else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

private struct ConnectionAuthority: Equatable {
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
        host == protectionSpace.host.lowercased() && port == protectionSpace.port
    }
}
