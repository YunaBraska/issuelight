import Foundation
import Security

enum ProviderHTTPError: Error {
    case failure(ConnectionFailure)
}

enum ProviderHTTPAuthentication {
    case none
    case basic(username: String, password: String)
    case clientIdentity(SecIdentity)
}

struct ProviderHTTPResponse {
    let data: Data
    let statusCode: Int
    let headers: [String: String]

    func headerValue(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

final class ProviderHTTPSession {
    private let authentication: ProviderHTTPAuthentication
    private let delegate: ProviderHTTPSessionDelegate
    private let session: URLSession

    init(
        source: MonitoringSource,
        authentication: ProviderHTTPAuthentication,
        trustedServerCertificate: SecCertificate?,
        configuration: URLSessionConfiguration
    ) throws {
        guard let authority = ProviderHTTPAuthority(url: source.endpoint) else {
            throw ProviderHTTPError.failure(.invalidConfiguration([.missingHost]))
        }
        if case .customCertificate = source.serverTrust,
           trustedServerCertificate == nil {
            throw ProviderHTTPError.failure(.serverCertificateNotAvailable)
        }

        self.authentication = authentication
        let delegate = ProviderHTTPSessionDelegate(
            authority: authority,
            trust: source.serverTrust,
            authentication: authentication,
            trustedServerCertificate: trustedServerCertificate
        )
        self.delegate = delegate
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    func authenticated(_ request: URLRequest) -> URLRequest {
        guard case .basic(let username, let password) = authentication else {
            return request
        }
        var value = request
        let token = Data("\(username):\(password)".utf8).base64EncodedString()
        value.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        return value
    }

    func data(for request: URLRequest) async throws -> Data {
        let response = try await response(for: request)
        if let failure = Self.failure(forStatusCode: response.statusCode) {
            throw ProviderHTTPError.failure(failure)
        }
        return response.data
    }

    func response(for request: URLRequest) async throws -> ProviderHTTPResponse {
        do {
            let (data, response) = try await session.data(for: authenticated(request))
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ProviderHTTPError.failure(.incompatibleResponse)
            }
            let headers = httpResponse.allHeaderFields.reduce(into: [String: String]()) { values, field in
                guard let name = field.key as? String,
                      let value = field.value as? String else { return }
                values[name] = value
            }
            return ProviderHTTPResponse(
                data: data,
                statusCode: httpResponse.statusCode,
                headers: headers
            )
        } catch let error as ProviderHTTPError {
            throw error
        } catch {
            if delegate.hasRejectedServerTrust {
                throw ProviderHTTPError.failure(.serverTrust)
            }
            let failure = Self.failure(for: error)
            if failure == .cancelled {
                throw ProviderHTTPError.failure(.cancelled)
            }
            if delegate.hasReceivedClientCertificateChallenge {
                throw ProviderHTTPError.failure(.clientCertificateRejected)
            }
            throw ProviderHTTPError.failure(failure)
        }
    }

    func close() {
        session.finishTasksAndInvalidate()
    }

    static func failure(forStatusCode statusCode: Int) -> ConnectionFailure? {
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

    static func failure(for error: Error) -> ConnectionFailure {
        let code = (error as? URLError)?.code
        switch code {
        case .cancelled:
            return .cancelled
        case .serverCertificateHasBadDate,
             .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid:
            return .serverTrust
        case .clientCertificateRejected,
             .clientCertificateRequired:
            return .clientCertificateRejected
        case .secureConnectionFailed:
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

private final class ProviderHTTPSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    private let authority: ProviderHTTPAuthority
    private let trust: ServerTrustConfiguration
    private let authentication: ProviderHTTPAuthentication
    private let trustedServerCertificate: SecCertificate?
    private let challengeStateLock = NSLock()
    private var rejectedServerTrust = false
    private var receivedClientCertificateChallenge = false

    var hasRejectedServerTrust: Bool {
        challengeStateLock.lock()
        defer { challengeStateLock.unlock() }
        return rejectedServerTrust
    }

    var hasReceivedClientCertificateChallenge: Bool {
        challengeStateLock.lock()
        defer { challengeStateLock.unlock() }
        return receivedClientCertificateChallenge
    }

    init(
        authority: ProviderHTTPAuthority,
        trust: ServerTrustConfiguration,
        authentication: ProviderHTTPAuthentication,
        trustedServerCertificate: SecCertificate?
    ) {
        self.authority = authority
        self.trust = trust
        self.authentication = authentication
        self.trustedServerCertificate = trustedServerCertificate
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate,
           authority.matches(challenge.protectionSpace) {
            recordClientCertificateChallenge()
            if case .clientIdentity(let identity) = authentication {
                completionHandler(
                    .useCredential,
                    URLCredential(identity: identity, certificates: nil, persistence: .forSession)
                )
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
            return
        }

        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              authority.matches(challenge.protectionSpace),
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        switch trust {
        case .disabled:
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        case .customCertificate:
            guard let trustedServerCertificate,
                  SecTrustSetPolicies(
                    serverTrust,
                    SecPolicyCreateSSL(true, authority.host as CFString)
                  ) == errSecSuccess,
                  SecTrustSetAnchorCertificates(
                    serverTrust,
                    [trustedServerCertificate] as CFArray
                  ) == errSecSuccess,
                  SecTrustSetAnchorCertificatesOnly(serverTrust, false) == errSecSuccess,
                  SecTrustEvaluateWithError(serverTrust, nil) else {
                rejectServerTrust(completionHandler)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        case .pinnedCertificate(let expectedSHA256):
            guard let chain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
                  let leaf = chain.first,
                  let expected = ServerCertificateFingerprint.normalizedSHA256(expectedSHA256),
                  ServerCertificateFingerprint.sha256(of: leaf) == expected,
                  SecTrustSetPolicies(
                    serverTrust,
                    SecPolicyCreateSSL(true, authority.host as CFString)
                  ) == errSecSuccess,
                  SecTrustSetAnchorCertificates(serverTrust, [leaf] as CFArray) == errSecSuccess,
                  SecTrustSetAnchorCertificatesOnly(serverTrust, true) == errSecSuccess,
                  SecTrustEvaluateWithError(serverTrust, nil) else {
                rejectServerTrust(completionHandler)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        case .system:
            completionHandler(.performDefaultHandling, nil)
        }
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
              case .basic(let username, let password) = authentication else {
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
              ProviderHTTPAuthority(url: url) == authority else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    private func rejectServerTrust(
        _ completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        challengeStateLock.lock()
        rejectedServerTrust = true
        challengeStateLock.unlock()
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    private func recordClientCertificateChallenge() {
        challengeStateLock.lock()
        receivedClientCertificateChallenge = true
        challengeStateLock.unlock()
    }
}

private struct ProviderHTTPAuthority: Equatable {
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
