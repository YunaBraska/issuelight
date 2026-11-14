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

public struct RemoteLoginConfiguration: Codable, Equatable, Sendable {
    public var username: String
    public var port: Int

    public init(username: String = "", port: Int) {
        self.username = username
        self.port = port
    }
}

public struct RemoteAccessConfiguration: Codable, Equatable, Sendable {
    public var ssh: RemoteLoginConfiguration?
    public var rdp: RemoteLoginConfiguration?

    public init(
        ssh: RemoteLoginConfiguration? = nil,
        rdp: RemoteLoginConfiguration? = nil
    ) {
        self.ssh = ssh
        self.rdp = rdp
    }
}

public struct SSHTunnelConfiguration: Codable, Equatable, Sendable {
    public var bastionHost: String
    public var username: String
    public var port: Int
    public var identityFilePath: String?
    public var preferredLocalPort: Int?

    public init(
        bastionHost: String,
        username: String,
        port: Int = 22,
        identityFilePath: String? = nil,
        preferredLocalPort: Int? = nil
    ) {
        self.bastionHost = bastionHost
        self.username = username
        self.port = port
        self.identityFilePath = identityFilePath
        self.preferredLocalPort = preferredLocalPort
    }
}

public struct MonitoringWebConfiguration: Codable, Equatable, Sendable {
    public var baseURL: URL
    public var automaticSSHTunnel: SSHTunnelConfiguration?

    public init(baseURL: URL, automaticSSHTunnel: SSHTunnelConfiguration? = nil) {
        self.baseURL = baseURL
        self.automaticSSHTunnel = automaticSSHTunnel
    }
}

public struct MonitoringSource: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var providerID: ProviderID
    public var endpoint: URL
    public var isEnabled: Bool
    public var authentication: AuthenticationConfiguration
    public var serverTrust: ServerTrustConfiguration
    public var web: MonitoringWebConfiguration?
    public var remoteAccess: RemoteAccessConfiguration?

    public init(
        id: UUID = UUID(),
        name: String,
        providerID: ProviderID,
        endpoint: URL,
        isEnabled: Bool = true,
        authentication: AuthenticationConfiguration,
        serverTrust: ServerTrustConfiguration = .system,
        web: MonitoringWebConfiguration? = nil,
        remoteAccess: RemoteAccessConfiguration? = nil
    ) {
        self.id = id
        self.name = name
        self.providerID = providerID
        self.endpoint = endpoint
        self.isEnabled = isEnabled
        self.authentication = authentication
        self.serverTrust = serverTrust
        self.web = web
        self.remoteAccess = remoteAccess
    }

    /// The persistent Keychain reference for source-specific CA trust, when configured.
    public var customServerCertificateID: String? {
        guard case .customCertificate(let certificateID) = serverTrust else {
            return nil
        }
        return certificateID
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
    case missingServerCertificate
    case invalidPinnedCertificate
    case unsupportedAuthentication(AuthenticationMethod)
    case unsupportedPath(String)
    case invalidWebURL
    case invalidRemotePort(Int)
    case emptyBastionHost
    case emptyBastionUsername
    case secureWebTunnelUnsupported
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

        if case .customCertificate(let certificateID) = source.serverTrust,
           certificateID.isEmpty {
            issues.append(.missingServerCertificate)
        }
        if case .pinnedCertificate(let sha256) = source.serverTrust,
           ServerCertificateFingerprint.normalizedSHA256(sha256) == nil {
            issues.append(.invalidPinnedCertificate)
        }

        if let web = source.web {
            let webComponents = URLComponents(url: web.baseURL, resolvingAgainstBaseURL: false)
            let webScheme = webComponents?.scheme?.lowercased()
            if !["http", "https"].contains(webScheme)
                || webComponents?.host?.isEmpty != false
                || webComponents?.user != nil
                || webComponents?.password != nil
                || webComponents?.query != nil
                || webComponents?.fragment != nil {
                issues.append(.invalidWebURL)
            }
            if let tunnel = web.automaticSSHTunnel {
                if tunnel.bastionHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    issues.append(.emptyBastionHost)
                }
                if tunnel.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    issues.append(.emptyBastionUsername)
                }
                if !Self.isValidPort(tunnel.port) {
                    issues.append(.invalidRemotePort(tunnel.port))
                }
                if let localPort = tunnel.preferredLocalPort, !Self.isValidPort(localPort) {
                    issues.append(.invalidRemotePort(localPort))
                }
                if webScheme == "https" {
                    issues.append(.secureWebTunnelUnsupported)
                }
            }
        }

        if let ssh = source.remoteAccess?.ssh, !Self.isValidPort(ssh.port) {
            issues.append(.invalidRemotePort(ssh.port))
        }
        if let rdp = source.remoteAccess?.rdp, !Self.isValidPort(rdp.port) {
            issues.append(.invalidRemotePort(rdp.port))
        }

        return issues
    }

    private static func isValidPort(_ port: Int) -> Bool {
        (1...65_535).contains(port)
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
