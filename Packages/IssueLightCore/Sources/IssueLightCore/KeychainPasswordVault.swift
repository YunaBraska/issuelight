import Foundation
import LocalAuthentication
import Security

public struct BasicCredentialScope: Equatable, Sendable {
    public let sourceID: UUID
    public let server: String
    public let port: Int
    public let scheme: String
    public let account: String

    public init(source: MonitoringSource) throws {
        guard case .basic(let username) = source.authentication else {
            throw CredentialScopeError.basicAuthenticationRequired
        }
        guard let components = URLComponents(url: source.endpoint, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            throw CredentialScopeError.invalidEndpoint
        }

        sourceID = source.id
        server = host
        port = components.port ?? (scheme == "https" ? 443 : 80)
        self.scheme = scheme
        account = username
    }
}

public struct APIKeyCredentialScope: Equatable, Sendable {
    public let sourceID: UUID
    public let server: String
    public let port: Int
    public let scheme: String
    public let account: String

    public init(source: MonitoringSource) throws {
        guard case .apiKey(let username) = source.authentication else {
            throw CredentialScopeError.apiKeyAuthenticationRequired
        }
        guard let components = URLComponents(url: source.endpoint, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            throw CredentialScopeError.invalidEndpoint
        }

        sourceID = source.id
        server = host
        port = components.port ?? (scheme == "https" ? 443 : 80)
        self.scheme = scheme
        account = username.isEmpty ? "IssueLight API key" : username
    }
}

public enum CredentialScopeError: Error, Equatable {
    case basicAuthenticationRequired
    case apiKeyAuthenticationRequired
    case invalidEndpoint
}

public enum KeychainPasswordVaultError: Error, Equatable {
    case interactionNotAllowed
    case unexpectedStatus(OSStatus)
    case invalidStoredPassword
}

public actor KeychainPasswordVault {
    private let keychainContext: KeychainAccessContext?

    public init() {
        keychainContext = nil
    }

    init(keychainContext: KeychainAccessContext) {
        self.keychainContext = keychainContext
    }

    public func password(for scope: BasicCredentialScope) throws -> String? {
        try credentialSecret(for: scope)
    }

    public func apiKey(for scope: APIKeyCredentialScope) throws -> String? {
        try credentialSecret(for: scope)
    }

    public func containsPassword(for scope: BasicCredentialScope) throws -> Bool {
        try containsCredentialSecret(for: scope)
    }

    public func containsAPIKey(for scope: APIKeyCredentialScope) throws -> Bool {
        try containsCredentialSecret(for: scope)
    }

    public func store(_ password: String, for scope: BasicCredentialScope) throws {
        try storeCredentialSecret(password, for: scope)
    }

    public func store(_ apiKey: String, for scope: APIKeyCredentialScope) throws {
        try storeCredentialSecret(apiKey, for: scope)
    }

    public func deletePassword(for scope: BasicCredentialScope) throws {
        try deleteCredentialSecret(for: scope)
    }

    public func deleteAPIKey(for scope: APIKeyCredentialScope) throws {
        try deleteCredentialSecret(for: scope)
    }

    func credentialSecret<Scope: KeychainCredentialScope>(for scope: Scope) throws -> String? {
        guard try containsCredentialSecret(for: scope) else { return nil }

        var query = keychainQuery(for: scope)
        query = keychainContext?.matching(query) ?? query
        query[kSecAttrLabel as String] = scope.ownershipLabel
        let authenticationContext = LAContext()
        authenticationContext.interactionNotAllowed = true
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = authenticationContext

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        if status == errSecInteractionNotAllowed {
            throw KeychainPasswordVaultError.interactionNotAllowed
        }
        guard status == errSecSuccess else {
            throw KeychainPasswordVaultError.unexpectedStatus(status)
        }
        guard let data = result as? Data, let secret = String(data: data, encoding: .utf8) else {
            throw KeychainPasswordVaultError.invalidStoredPassword
        }
        return secret
    }

    func containsCredentialSecret<Scope: KeychainCredentialScope>(for scope: Scope) throws -> Bool {
        var query = keychainQuery(for: scope)
        query = keychainContext?.matching(query) ?? query
        let authenticationContext = LAContext()
        authenticationContext.interactionNotAllowed = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = authenticationContext

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess,
              let attributes = result as? [String: Any],
              attributes[kSecAttrLabel as String] as? String == scope.ownershipLabel else {
            throw KeychainPasswordVaultError.interactionNotAllowed
        }
        return true
    }

    func storeCredentialSecret<Scope: KeychainCredentialScope>(
        _ secret: String,
        for scope: Scope
    ) throws {
        var query = keychainQuery(for: scope)
        query = keychainContext?.matching(query) ?? query
        _ = try containsCredentialSecret(for: scope)
        query[kSecAttrLabel as String] = scope.ownershipLabel
        let attributes = [kSecValueData as String: Data(secret.utf8)]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainPasswordVaultError.unexpectedStatus(updateStatus)
        }

        var newItem = keychainContext?.adding(keychainQuery(for: scope)) ?? keychainQuery(for: scope)
        newItem[kSecAttrLabel as String] = scope.ownershipLabel
        newItem[kSecValueData as String] = Data(secret.utf8)
        let addStatus = SecItemAdd(newItem as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainPasswordVaultError.unexpectedStatus(addStatus)
        }
    }

    func deleteCredentialSecret<Scope: KeychainCredentialScope>(for scope: Scope) throws {
        guard try containsCredentialSecret(for: scope) else { return }
        var query = keychainQuery(for: scope)
        query = keychainContext?.matching(query) ?? query
        query[kSecAttrLabel as String] = scope.ownershipLabel
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainPasswordVaultError.unexpectedStatus(status)
        }
    }

    func keychainQuery<Scope: KeychainCredentialScope>(for scope: Scope) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrAccount as String: scope.account,
            kSecAttrServer as String: scope.server,
            kSecAttrPort as String: scope.port,
            kSecAttrProtocol as String: scope.scheme == "https" ? kSecAttrProtocolHTTPS : kSecAttrProtocolHTTP,
            kSecAttrAuthenticationType as String: scope.authenticationType,
            kSecAttrPath as String: "/issuelight/sources/\(scope.sourceID.uuidString.lowercased())",
        ]
        if keychainContext == nil {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }
}

protocol KeychainCredentialScope {
    var sourceID: UUID { get }
    var server: String { get }
    var port: Int { get }
    var scheme: String { get }
    var account: String { get }
    var authenticationType: CFString { get }
    var ownershipLabel: String { get }
}

extension BasicCredentialScope: KeychainCredentialScope {
    var authenticationType: CFString { kSecAttrAuthenticationTypeHTTPBasic }
    var ownershipLabel: String {
        "IssueLight Basic credential \(sourceID.uuidString.lowercased())"
    }
}

extension APIKeyCredentialScope: KeychainCredentialScope {
    var authenticationType: CFString { kSecAttrAuthenticationTypeDefault }
    var ownershipLabel: String {
        "IssueLight API key \(sourceID.uuidString.lowercased())"
    }
}
