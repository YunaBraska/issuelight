import Foundation
import LocalAuthentication
import Security

public struct ClientIdentityDescriptor: Equatable, Identifiable, Sendable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

public enum KeychainIdentityCatalogError: Error, Equatable {
    case interactionNotAllowed
    case unexpectedStatus(OSStatus)
    case malformedKeychainResult
    case invalidPersistentReference
    case noIdentityInPKCS12
}

public enum KeychainInteraction: Equatable, Sendable {
    case allow
    case fail
}

public actor KeychainIdentityCatalog {
    private let accessContext: KeychainAccessContext?

    public init() {
        accessContext = nil
    }

    init(accessContext: KeychainAccessContext) {
        self.accessContext = accessContext
    }

    public func identities() throws -> [ClientIdentityDescriptor] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            (accessContext?.matching(query) ?? query) as CFDictionary,
            &result
        )
        if status == errSecItemNotFound {
            return []
        }
        guard status == errSecSuccess else {
            throw KeychainIdentityCatalogError.unexpectedStatus(status)
        }
        guard let identities = result as? [SecIdentity] else {
            throw KeychainIdentityCatalogError.malformedKeychainResult
        }

        return try identities.map { identity in
            ClientIdentityDescriptor(
                id: try persistentReference(for: identity).base64EncodedString(),
                displayName: displayName(for: identity)
            )
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    public func identity(
        id: String,
        interaction: KeychainInteraction = .fail
    ) throws -> SecIdentity? {
        guard let reference = Data(base64Encoded: id) else {
            throw KeychainIdentityCatalogError.invalidPersistentReference
        }
        let authenticationContext = LAContext()
        authenticationContext.interactionNotAllowed = interaction == .fail
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecValuePersistentRef as String: reference,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: authenticationContext,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            (accessContext?.matching(query) ?? query) as CFDictionary,
            &result
        )
        if status == errSecItemNotFound {
            if let accessContext {
                var fallbackQuery: [String: Any] = [
                    kSecClass as String: kSecClassIdentity,
                    kSecReturnRef as String: true,
                    kSecMatchLimit as String: kSecMatchLimitAll,
                ]
                if interaction == .fail {
                    fallbackQuery[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
                }
                var fallbackResult: CFTypeRef?
                let fallbackStatus = SecItemCopyMatching(
                    accessContext.matching(fallbackQuery) as CFDictionary,
                    &fallbackResult
                )
                if fallbackStatus == errSecSuccess, let identities = fallbackResult as? [SecIdentity] {
                    return identities.first { identity in
                        (try? persistentReference(for: identity)) == reference
                    }
                }
            }
            return nil
        }
        if status == errSecInteractionNotAllowed {
            throw KeychainIdentityCatalogError.interactionNotAllowed
        }
        guard status == errSecSuccess else {
            throw KeychainIdentityCatalogError.unexpectedStatus(status)
        }
        guard let result, CFGetTypeID(result) == SecIdentityGetTypeID() else {
            throw KeychainIdentityCatalogError.malformedKeychainResult
        }
        let identity = unsafeBitCast(result, to: SecIdentity.self)
        return identity
    }

    public func importPKCS12(at fileURL: URL, password: String) throws -> ClientIdentityDescriptor {
        let data = try Data(contentsOf: fileURL)
        var options: [String: Any] = [kSecImportExportPassphrase as String: password]
        if let accessContext {
            options[kSecImportExportKeychain as String] = accessContext.keychain
        }
        var rawItems: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &rawItems)
        guard status == errSecSuccess else {
            throw KeychainIdentityCatalogError.unexpectedStatus(status)
        }
        guard let items = rawItems as? [[String: Any]],
              let identityValue = items.compactMap({ $0[kSecImportItemIdentity as String] }).first,
              CFGetTypeID(identityValue as CFTypeRef) == SecIdentityGetTypeID() else {
            throw KeychainIdentityCatalogError.noIdentityInPKCS12
        }
        let identity = unsafeBitCast(identityValue as CFTypeRef, to: SecIdentity.self)

        let imported = ClientIdentityDescriptor(
            id: try persistentReference(for: identity).base64EncodedString(),
            displayName: displayName(for: identity)
        )
        guard accessContext != nil else {
            return imported
        }
        return try identities().first(where: { $0.displayName == imported.displayName }) ?? imported
    }

    private func persistentReference(for identity: SecIdentity) throws -> Data {
        let authenticationContext = LAContext()
        authenticationContext.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecValueRef as String: identity,
            kSecReturnPersistentRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: authenticationContext,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            (accessContext?.matching(query) ?? query) as CFDictionary,
            &result
        )
        if status == errSecInteractionNotAllowed {
            throw KeychainIdentityCatalogError.interactionNotAllowed
        }
        guard status == errSecSuccess else {
            throw KeychainIdentityCatalogError.unexpectedStatus(status)
        }
        guard let reference = result as? Data else {
            throw KeychainIdentityCatalogError.malformedKeychainResult
        }
        return reference
    }

    private func displayName(for identity: SecIdentity) -> String {
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
              let certificate,
              let summary = SecCertificateCopySubjectSummary(certificate) as String? else {
            return "Unnamed certificate"
        }
        return summary
    }
}
