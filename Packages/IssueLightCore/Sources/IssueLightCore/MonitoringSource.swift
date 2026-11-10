import Foundation

public struct ProviderID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public enum AuthenticationConfiguration: Codable, Equatable, Sendable {
    case basic(username: String)
    case clientCertificate(identityID: String)

    public var method: AuthenticationMethod {
        switch self {
        case .basic:
            return .basic
        case .clientCertificate:
            return .clientCertificate
        }
    }
}

public enum AuthenticationMethod: String, Codable, CaseIterable, Sendable {
    case basic
    case clientCertificate
}

public enum ServerTrustConfiguration: Codable, Equatable, Sendable {
    case system
    case customCertificate(certificateID: String)
    case pinnedCertificate(sha256: String)
    case disabled

    public var verifiesServerCertificate: Bool {
        self != .disabled
    }

    public var method: ServerTrustMethod {
        switch self {
        case .system:
            return .system
        case .customCertificate:
            return .customCertificate
        case .pinnedCertificate:
            return .pinnedCertificate
        case .disabled:
            return .disabled
        }
    }
}

public enum ServerTrustMethod: String, Codable, CaseIterable, Sendable {
    case system
    case customCertificate
    case pinnedCertificate
    case disabled
}

public struct MonitoringSource: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var providerID: ProviderID
    public var endpoint: URL
    public var isEnabled: Bool
    public var authentication: AuthenticationConfiguration
    public var serverTrust: ServerTrustConfiguration

    public init(
        id: UUID = UUID(),
        name: String,
        providerID: ProviderID,
        endpoint: URL,
        isEnabled: Bool = true,
        authentication: AuthenticationConfiguration,
        serverTrust: ServerTrustConfiguration = .system
    ) {
        self.id = id
        self.name = name
        self.providerID = providerID
        self.endpoint = endpoint
        self.isEnabled = isEnabled
        self.authentication = authentication
        self.serverTrust = serverTrust
    }

    @discardableResult
    public mutating func updateEndpoint(_ newEndpoint: URL) -> Bool {
        let authorityChanged = endpoint.authority != newEndpoint.authority
        if authorityChanged {
            serverTrust = .system
        }
        endpoint = newEndpoint
        return authorityChanged
    }

    public mutating func setServerCertificateVerification(enabled: Bool) {
        if enabled {
            if serverTrust == .disabled {
                serverTrust = .system
            }
        } else {
            serverTrust = .disabled
        }
    }
}

public enum SourceValidationIssue: Error, Equatable, Hashable, Sendable {
    case emptyName
    case unsupportedScheme(String?)
    case missingHost
    case embeddedCredentials
    case queryNotAllowed
    case fragmentNotAllowed
    case emptyUsername
    case invalidUsername
    case missingClientIdentity
    case unsupportedAuthentication(AuthenticationMethod)
    case unsupportedPath(String)
}

public enum MonitoringSourceValidator {
    public static func validateSharedFields(_ source: MonitoringSource) -> [SourceValidationIssue] {
        var issues: [SourceValidationIssue] = []
        let components = URLComponents(url: source.endpoint, resolvingAgainstBaseURL: false)

        if source.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.emptyName)
        }

        let scheme = components?.scheme?.lowercased()
        if scheme != "http" && scheme != "https" {
            issues.append(.unsupportedScheme(scheme))
        }

        if components?.host?.isEmpty != false {
            issues.append(.missingHost)
        }

        if components?.user != nil || components?.password != nil {
            issues.append(.embeddedCredentials)
        }

        if components?.query != nil {
            issues.append(.queryNotAllowed)
        }

        if components?.fragment != nil {
            issues.append(.fragmentNotAllowed)
        }

        switch source.authentication {
        case .basic(let username):
            if username.isEmpty {
                issues.append(.emptyUsername)
            } else if username.contains(":") {
                issues.append(.invalidUsername)
            }
        case .clientCertificate(let identityID):
            if identityID.isEmpty {
                issues.append(.missingClientIdentity)
            }
        }

        return issues
    }
}

extension URL {
    fileprivate var authority: SourceAuthority? {
        guard let components = URLComponents(url: self, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased() else {
            return nil
        }

        let port = components.port ?? (scheme == "https" ? 443 : 80)
        return SourceAuthority(scheme: scheme, host: host, port: port)
    }
}

private struct SourceAuthority: Equatable {
    let scheme: String
    let host: String
    let port: Int
}
