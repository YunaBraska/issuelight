import Foundation
import Security

public struct PresentedServerCertificate: Equatable, Identifiable, Sendable {
    public let endpoint: URL
    public let subject: String
    public let sha256Fingerprint: String

    public var id: String {
        "\(endpoint.absoluteString)|\(sha256Fingerprint)"
    }

    public init(endpoint: URL, subject: String, sha256Fingerprint: String) {
        self.endpoint = endpoint
        self.subject = subject
        self.sha256Fingerprint = sha256Fingerprint
    }
}

public enum PresentedServerCertificateResult: Equatable, Sendable {
    case fetched(PresentedServerCertificate)
    case failed(ConnectionFailure)
}

public enum PresentedServerCertificateFetcher {
    public static func fetch(
        from endpoint: URL,
        socksProxy: ProviderSOCKSProxy? = nil
    ) async -> PresentedServerCertificateResult {
        guard endpoint.host?.isEmpty == false else {
            return .failed(.invalidConfiguration([.missingHost]))
        }
        guard endpoint.scheme?.lowercased() == "https" else {
            return .failed(.invalidConfiguration([.unsupportedScheme(endpoint.scheme)]))
        }

        let delegate = PresentedServerCertificateDelegate(endpoint: endpoint)
        let configuration = URLSessionConfiguration.ephemeral.routed(through: socksProxy)
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "HEAD"
        do {
            _ = try await session.data(for: request)
        } catch {
            if let certificate = delegate.presentedCertificate {
                return .fetched(certificate)
            }
            if Task.isCancelled {
                return .failed(.cancelled)
            }
            return .failed(ProviderHTTPSession.failure(for: error))
        }

        guard let certificate = delegate.presentedCertificate else {
            return .failed(.tls)
        }
        return .fetched(certificate)
    }
}

private final class PresentedServerCertificateDelegate: NSObject, URLSessionDelegate {
    private let authority: PresentedServerCertificateAuthority
    private let endpoint: URL
    private let lock = NSLock()
    private var storedCertificate: PresentedServerCertificate?

    var presentedCertificate: PresentedServerCertificate? {
        lock.lock()
        defer { lock.unlock() }
        return storedCertificate
    }

    init(endpoint: URL) {
        self.endpoint = endpoint
        authority = PresentedServerCertificateAuthority(url: endpoint)!
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              authority.matches(challenge.protectionSpace),
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let subject = SecCertificateCopySubjectSummary(leaf) as String? ?? authority.host
        let certificate = PresentedServerCertificate(
            endpoint: endpoint,
            subject: subject,
            sha256Fingerprint: ServerCertificateFingerprint.sha256(of: leaf)
        )
        lock.lock()
        storedCertificate = certificate
        lock.unlock()
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private struct PresentedServerCertificateAuthority {
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
