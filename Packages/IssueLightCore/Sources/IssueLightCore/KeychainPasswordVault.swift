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

public enum CredentialScopeError: Error, Equatable {
    case basicAuthenticationRequired
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
        guard try containsPassword(for: scope) else {
            return nil
        }

        var query = keychainQuery(for: scope)
        query = keychainContext?.matching(query) ?? query
        query[kSecAttrLabel as String] = ownershipLabel(for: scope)
        let authenticationContext = LAContext()
        authenticationContext.interactionNotAllowed = true
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = authenticationContext

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        if status == errSecInteractionNotAllowed {
            throw KeychainPasswordVaultError.interactionNotAllowed
        }
        guard status == errSecSuccess else {
            throw KeychainPasswordVaultError.unexpectedStatus(status)
        }
        guard let data = result as? Data, let password = String(data: data, encoding: .utf8) else {
            throw KeychainPasswordVaultError.invalidStoredPassword
        }
        return password
    }

    public func containsPassword(for scope: BasicCredentialScope) throws -> Bool {
        var query = keychainQuery(for: scope)
        query = keychainContext?.matching(query) ?? query
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return false
        }
        guard status == errSecSuccess,
              let attributes = result as? [String: Any],
              attributes[kSecAttrLabel as String] as? String == ownershipLabel(for: scope) else {
            throw KeychainPasswordVaultError.interactionNotAllowed
        }
        return true
    }

    public func store(_ password: String, for scope: BasicCredentialScope) throws {
        var query = keychainQuery(for: scope)
        query = keychainContext?.matching(query) ?? query
        _ = try containsPassword(for: scope)
        query[kSecAttrLabel as String] = ownershipLabel(for: scope)
        let attributes = [kSecValueData as String: Data(password.utf8)]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainPasswordVaultError.unexpectedStatus(updateStatus)
        }

        var newItem = keychainContext?.adding(keychainQuery(for: scope)) ?? keychainQuery(for: scope)
        newItem[kSecAttrLabel as String] = ownershipLabel(for: scope)
        newItem[kSecValueData as String] = Data(password.utf8)
        let addStatus = SecItemAdd(newItem as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainPasswordVaultError.unexpectedStatus(addStatus)
        }
    }

    public func deletePassword(for scope: BasicCredentialScope) throws {
        guard try containsPassword(for: scope) else {
            return
        }
        var query = keychainQuery(for: scope)
        query = keychainContext?.matching(query) ?? query
        query[kSecAttrLabel as String] = ownershipLabel(for: scope)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainPasswordVaultError.unexpectedStatus(status)
        }
    }

    private func ownershipLabel(for scope: BasicCredentialScope) -> String {
        "IssueLight Basic credential \(scope.sourceID.uuidString.lowercased())"
    }

    private func keychainQuery(for scope: BasicCredentialScope) -> [String: Any] {
        [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrAccount as String: scope.account,
            kSecAttrServer as String: scope.server,
            kSecAttrPort as String: scope.port,
            kSecAttrProtocol as String: scope.scheme == "https" ? kSecAttrProtocolHTTPS : kSecAttrProtocolHTTP,
            kSecAttrAuthenticationType as String: kSecAttrAuthenticationTypeHTTPBasic,
            kSecAttrPath as String: "/issuelight/sources/\(scope.sourceID.uuidString.lowercased())",
        ]
    }
}
